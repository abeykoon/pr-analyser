import ballerinax/googleapis.sheets as sheets;
import ballerinax/github;
import ballerina/http;
import ballerina/regex;
import ballerina/time;

//import ballerina/url;
//import ballerina/log;
//import ballerina/io;

@display {
    label: "RepositoriesToScan",
    description: "if you have more than one, specify comma separated"
}
configurable string repositoriesToScan = ?;

@display {
    label: "DateRange",
    description: "Specify the date range in format YYYY-MM-DD:YYYY-MM-DD (start date: end date)"
}
configurable string dateRange = ?;

configurable http:BearerTokenConfig gitHubOAuthConfig = ?;
configurable GSheetConfig gSheetConfig = ?;

type GSheetConfig record {
    string clientId;
    string clientSecret;
    string refreshToken;
    string spreadSheetID;
};

github:Client githubClient = check new ({
    auth: {
        token: gitHubOAuthConfig.token
    }
});

sheets:Client spreadsheetClient = check new ({
    auth: {
        clientId: gSheetConfig.clientId,
        clientSecret: gSheetConfig.clientSecret,
        refreshUrl: sheets:REFRESH_URL,
        refreshToken: gSheetConfig.refreshToken
    },
    retryConfig: {
        interval: 10,
        count: 6,
        backOffFactor: 1,
        maxWaitInterval: 15
    }
});

string[] GSheetHeaderColumns = ["Author", "State", "Url", "Title", "Base Branch", "Created Date", "Closed Date", "Dates to Close", "Review Comments Count", "Added line count", "Removed Line Count", "Labels", "Linked Issue"];

public function main() returns error? {

    //read inputs
    string[] repositories = regex:split(repositoriesToScan, ",");
    string[] datesUsedToQuery = regex:split(dateRange, ":");
    string startDate = datesUsedToQuery[0];
    string endDate = datesUsedToQuery[1];

    foreach string repositoryName in repositories {
        string repoNameWithoutOrgPrefix = getRepoNameWithoutOrgName(repositoryName); //need to do this due to an issue in Gsheet connector
        check createNewSheetIfRequired(gSheetConfig.spreadSheetID, repoNameWithoutOrgPrefix);
        check getClosedPRs(githubClient, repositoryName, startDate, endDate);
        check getOpenPRs(githubClient, repositoryName, startDate, endDate);
    }
}

function extractPRInfo(github:Client githubClient, string repositoryName, string githubQuery) returns error? {
    string? nextPageCurser = ();
    boolean hasNextPage = true;
    while hasNextPage {
        github:SearchResult searchResult = check githubClient->search(githubQuery, github:SEARCH_TYPE_PULL_REQUEST, 20, lastPageCursor = nextPageCurser);
        github:Issue[]|github:User[]|github:Organization[]|github:Repository[]|github:PullRequest[] results = searchResult.results;
        if results is github:PullRequest[] {
            foreach github:PullRequest pullRequest in results {
                string createdAt = pullRequest.createdAt ?: ""; //example - 2022-03-05T02:28:34Z
                string closedAt = pullRequest?.closedAt ?: "";
                string createdDate = regex:split(createdAt, "T")[0];
                string closedDate = regex:split(closedAt, "T")[0];
                int numOfDatesBetweenCreateAndClose = 0;
                //TODO: make separate method
                if (closedAt != "") {
                    time:Utc createdAtUtc = check time:utcFromString(createdAt);
                    time:Utc closedAtUtc = check time:utcFromString(closedAt);
                    numOfDatesBetweenCreateAndClose = <int>((time:utcDiffSeconds(createdAtUtc, closedAtUtc)).abs() / (60 * 60 * 24));
                } else {
                    time:Utc createdAtUtc = check time:utcFromString(createdAt);
                    numOfDatesBetweenCreateAndClose = <int>((time:utcDiffSeconds(createdAtUtc, time:utcNow())).abs() / (60 * 60 * 24)); //number of days since created
                }
                
                (string|int)[] PRInfo = [
                    pullRequest?.author is github:Actor ? (<github:Actor>pullRequest?.author).login : "Unknown User",
                    pullRequest.state ?: "",
                    pullRequest.url ?: "",
                    pullRequest.title ?: "",
                    pullRequest.baseRefName ?: "",
                    createdDate,
                    closedDate,
                    numOfDatesBetweenCreateAndClose,
                    pullRequest.pullRequestReviews is github:PullRequestReview[] ? (<github:PullRequestReview[]>pullRequest.pullRequestReviews).length() : 0, //check
                    pullRequest.additions ?: 0,
                    pullRequest.deletions ?: 0,
                    getCommaSeparatedLabelNames(pullRequest),
                    getCommaSeparatedReferencedIssues(pullRequest)

                ];
                string repoNameWithoutOrgPrefix = getRepoNameWithoutOrgName(repositoryName);
                check appendToGSheet(gSheetConfig.spreadSheetID, repoNameWithoutOrgPrefix, PRInfo);
            }
        }
        hasNextPage = searchResult.pageInfo.hasNextPage;
        nextPageCurser = searchResult.pageInfo.endCursor;
    }

}

function constructGithubQuery(string repositoryName, boolean isClosed, string startDate, string endDate) returns string {
    //repo:module-ballerinax-github is:pr is:closed author:sachinira created:>2022-07-15 
    string queryRepo = string `repo:${repositoryName}`;
    string queryElementType = "is:pr";
    string queryElementState = isClosed == true ? "is:closed" : "is:open";
    string queryDateRange = string `created:${startDate}..${endDate}`;
    return queryRepo + " " + queryElementType + " " + queryElementState + " " + queryDateRange;
}

function appendToGSheet(string spreadsheetID, string sheetName, (string|int)[] gSheetData) returns error? {
    _ = check spreadsheetClient->appendRowToSheet(spreadsheetID, sheetName, gSheetData);

}

function getRepoNameWithoutOrgName(string repositoryName) returns string {
    string orgRepoSeparator = "/";
    string repositoryNameWithoutOrgName = regex:split(repositoryName, orgRepoSeparator)[1];
    return repositoryNameWithoutOrgName;
}

function createNewSheetIfRequired(string spreadsheetID, string sheetName) returns error? {
    sheets:Sheet|error sheet = spreadsheetClient->getSheetByName(spreadsheetID, sheetName);
    if (sheet !is sheets:Sheet) {
        _ = check spreadsheetClient->addSheet(spreadsheetID, sheetName);
        check appendToGSheet(spreadsheetID, sheetName, GSheetHeaderColumns);
    }
}

function getCommaSeparatedLabelNames(github:PullRequest pullRequest) returns string {
    string pullRequestLabelNames = "";
    github:IssueLabels? issueLabels = pullRequest?.labels;
    if issueLabels is github:IssueLabels {
        github:Label[]? labelNodes = issueLabels?.nodes;
        if(labelNodes is github:Label[]) {
            foreach github:Label label in labelNodes {
                pullRequestLabelNames = pullRequestLabelNames + label.name + ", ";   
            }
        }
    }
    int? indexOfLastComma = string:lastIndexOf(str = pullRequestLabelNames, substr = ",");
    if(indexOfLastComma is int) {
       pullRequestLabelNames = pullRequestLabelNames.substring(0,indexOfLastComma);
    }
    return pullRequestLabelNames;
}

function getCommaSeparatedReferencedIssues(github:PullRequest pullRequest) returns string {
    string referencedIssues = "";
    github:RelatedIssues? relatedIssuesInfo =  pullRequest?.closingIssuesReferences;
    if relatedIssuesInfo is github:RelatedIssues {
        github:Issue[]? relatedIssueList = relatedIssuesInfo?.nodes;
        if relatedIssueList is github:Issue[] {
            foreach github:Issue relatedissue in relatedIssueList {
                referencedIssues = relatedissue.url.toString() + ",";                  
            }
        }

    }
    int? indexOfLastComma = string:lastIndexOf(str = referencedIssues, substr = ",");
    if(indexOfLastComma is int) {
        referencedIssues = referencedIssues.substring(0,indexOfLastComma);
    }
    return referencedIssues;
}


function getClosedPRs(github:Client githubClient, string repositoryName, string startDate, string endDate) returns error? {
    string query = constructGithubQuery(repositoryName, true, startDate, endDate);
    _ = check extractPRInfo(githubClient, repositoryName, query);
}

function getOpenPRs(github:Client githubClient, string repositoryName, string startDate, string endDate) returns error? {
    string query = constructGithubQuery(repositoryName, false, startDate, endDate);
    _ = check extractPRInfo(githubClient, repositoryName, query);
}
