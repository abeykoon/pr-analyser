import ballerinax/googleapis.sheets as sheets;
import ballerinax/github;
import ballerina/http;
import ballerina/regex;
import ballerina/time;
import ballerina/log;

@display {
    label: "RepositoriesToScan",
    description: "If you have more than one, specify comma separated. If not specified, it will look for information at Repositories tab of specified GSheet."
}
configurable string repositoriesToScan = "";

@display {
    label: "DateRange",
    description: "Specify the date range in format YYYY-MM-DD:YYYY-MM-DD (start date: end date). If not provided date range will be constructed for the previous month."
}
configurable string dateRange = "";

configurable http:BearerTokenConfig gitHubOAuthConfig = ?;
configurable GSheetConfig gSheetConfig = ?;

type GSheetConfig record {
    string clientId;
    string clientSecret;
    string refreshToken;
    string spreadSheetID;
};

type WorkSheetContext record {
    string spreadSheetId;
    string worksheetName;
    int lastRowNumberWithData = 0;
    string startingColumnInDataRange = "A";
    string endingColumnInDataRange;
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

final string[] & readonly GSheetHeaderColumns = ["Repository", "Author", "Author Email", "State", "Url", "Title", "Base Branch", "Created Date", "Closed Date", 
                                "Dates to Close", "Review Comments Count", "Approved By", "Added line count", 
                                "Removed Line Count", "Labels", "Linked Issue"];
final string[] & readonly monthsOfYear = ["Jan", "Feb,", "Mar", "April", "May", "June", "July", "Aug", "Sep", "Oct", "Nov", "Dec"];

const string endingColumnForGSheetData = "P";

const string sheetNameOfRepositories = "Repositories";
const string columnContainingRepositories = "A";
const string sheetNameOfTeamMembers = "Members";
const string rangeForTeamMemberInfo = "A2:B200";


public function main() returns error? {

    //read inputs
    string[] repositories;
    if repositoriesToScan != "" {
        repositories = regex:split(repositoriesToScan, ",");
    } else {
        log:printInfo(string `RepositoriesToScan is not provided. Program will look for this infomation in ${sheetNameOfRepositories} tab of the specified worksheet.`);
        repositories = check getRepositoryList(gSheetConfig.spreadSheetID, sheetNameOfRepositories, columnContainingRepositories);
    }
    string dateRangeToQuery = dateRange;
    boolean dateRangeProvidedByUser = true;
    if(dateRangeToQuery == "") {
        dateRangeProvidedByUser = false;
        dateRangeToQuery = getDateRangeForPreviousMonth();
        log:printInfo(string `Date range is not provided. Program will construct date range for previous month = ${dateRangeToQuery}`);
    }
    string[] datesUsedToQuery = regex:split(dateRangeToQuery, ":");
    string startDate = datesUsedToQuery[0];
    string endDate = datesUsedToQuery[1];

    map<string> teamMembers = check populateMemberInfo(gSheetConfig.spreadSheetID, sheetNameOfTeamMembers, rangeForTeamMemberInfo);
    string sheetName;
    if dateRangeProvidedByUser {
        sheetName = startDate + " " + endDate;
    } else {
        string sheetNameForMonth = check constructSheetName(startDate);    //construct sheet name for previous month
        sheetName = sheetNameForMonth;
    }
    WorkSheetContext workSheetContext = check createNewSheetIfRequired(gSheetConfig.spreadSheetID, sheetName);

    foreach string repositoryName in repositories {
        log:printInfo("Scanning repository" + repositoryName);
        
        string repoNameWithoutOrgPrefix = getRepoNameWithoutOrgName(repositoryName); //need to do this due to an issue in Gsheet connector
        
        github:PullRequest[] closedPullRequests = check getClosedPRs(githubClient, repositoryName, startDate, endDate);
        _ = check appendToGSheet(workSheetContext, check populatePRInfoToGSheetData(closedPullRequests, repoNameWithoutOrgPrefix, teamMembers));
       
        github:PullRequest[] openPullRequests = check getOpenPRs(githubClient, repositoryName, startDate, endDate);
        _ = check appendToGSheet(workSheetContext, check populatePRInfoToGSheetData(openPullRequests, repoNameWithoutOrgPrefix, teamMembers));
    }
}

function extractPRInfo(github:Client githubClient, string repositoryName, string githubQuery) returns github:PullRequest[]|error {
    github:PullRequest[] PRList = [];
    string? nextPageCurser = ();
    boolean hasNextPage = true;
    while hasNextPage {
        github:SearchResult searchResult = check githubClient->search(githubQuery, github:SEARCH_TYPE_PULL_REQUEST, 20, lastPageCursor = nextPageCurser);
        github:Issue[]|github:User[]|github:Organization[]|github:Repository[]|github:PullRequest[] results = searchResult.results;
        if results is github:PullRequest[] {
            foreach github:PullRequest pullRequest in results {
                PRList.push(pullRequest);
            }
        }
        hasNextPage = searchResult.pageInfo.hasNextPage;
        nextPageCurser = searchResult.pageInfo.endCursor;
    }
    return PRList;
}

function populatePRInfoToGSheetData(github:PullRequest[] pullRequests, string repositoryName, map<string> teamMembers) returns (string|int)[][]|error {
    (string|int)[][] gSheetData = [];
    foreach github:PullRequest pullRequest in pullRequests {
        boolean isPRSentByMember = checkIfPRIsFromTeam(pullRequest, teamMembers);
        if !isPRSentByMember {      //ignore PRs sent by non-members
            continue;
        }
        string createdAt = pullRequest.createdAt ?: ""; //example - 2022-03-05T02:28:34Z
        string closedAt = pullRequest?.closedAt ?: "";
        string createdDate = regex:split(createdAt, "T")[0];
        string closedDate = regex:split(closedAt, "T")[0];
        int numOfDatesBetweenCreateAndClose = check getDatesBetween(createdAt, closedAt);

        string PRAuthorGitHubId;
        string PRAuthorEmail ;
        [PRAuthorGitHubId, PRAuthorEmail] = getPRAuthor(pullRequest, teamMembers);

        (string|int)[] PRInfo = [
            repositoryName,
            PRAuthorGitHubId,
            PRAuthorEmail,
            pullRequest.state ?: "",
            pullRequest.url ?: "",
            pullRequest.title ?: "",
            pullRequest.baseRefName ?: "",
            createdDate,
            closedDate,
            numOfDatesBetweenCreateAndClose,
            pullRequest.pullRequestReviews is github:PullRequestReview[] ? (<github:PullRequestReview[]>pullRequest.pullRequestReviews).length() : 0, //check
            check getMembersApprovedPR(pullRequest, teamMembers),
            pullRequest.additions ?: 0,
            pullRequest.deletions ?: 0,
            getCommaSeparatedLabelNames(pullRequest),
            getCommaSeparatedReferencedIssues(pullRequest)
        ];

        gSheetData.push(PRInfo);
    }
    
    return gSheetData;
}

function constructGithubQuery(string repositoryName, boolean isClosed, string startDate, string endDate) returns string {
    //repo:module-ballerinax-github is:pr is:closed author:sachinira created:>2022-07-15 
    string queryRepo = string `repo:${repositoryName}`;
    string queryElementType = "is:pr";
    string queryElementState = isClosed == true ? "is:closed" : "is:open";
    string queryDateRange = string `created:${startDate}..${endDate}`;
    return queryRepo + " " + queryElementType + " " + queryElementState + " " + queryDateRange;
}

function appendToGSheet(WorkSheetContext workSheetContext, (string|int)[][] gSheetData) returns error? {
    if gSheetData.length() != 0 {
        string a1Notation = populateA1Notation(workSheetContext, gSheetData);
        sheets:Range data = {
            a1Notation: a1Notation,
            values: gSheetData
        };
        _ = check spreadsheetClient->setRange(workSheetContext.spreadSheetId, workSheetContext.worksheetName, data);
        updateWorkSheetContext(workSheetContext, gSheetData);
    }
}

function appendSingleRowToGSheet(WorkSheetContext workSheetContext, (string|int)[] data) returns error? {
    _ = check spreadsheetClient -> appendRowToSheet(workSheetContext.spreadSheetId, workSheetContext.worksheetName, data);
    workSheetContext.lastRowNumberWithData = workSheetContext.lastRowNumberWithData + 1;
}

function populateA1Notation(WorkSheetContext workSheetContext, (string|int)[][] gSheetData) returns string {
    int currentLastRowNumberWithData = workSheetContext.lastRowNumberWithData;
    int newStartRowNumberWithData = workSheetContext.lastRowNumberWithData + 1;
    int newLastRowNumberWithData = currentLastRowNumberWithData + gSheetData.length();
    string a1NotationForData = workSheetContext.startingColumnInDataRange.toString()        //Example A1Notation - A1:B3
        + newStartRowNumberWithData.toString()
        + ":"
        + workSheetContext.endingColumnInDataRange
        + newLastRowNumberWithData.toString();
    return a1NotationForData;
}

function updateWorkSheetContext(WorkSheetContext workSheetContext, (string|int)[][] gSheetData) {
    workSheetContext.lastRowNumberWithData = workSheetContext.lastRowNumberWithData + gSheetData.length();
}

function getRepoNameWithoutOrgName(string repositoryName) returns string {
    string orgRepoSeparator = "/";
    string repositoryNameWithoutOrgName = regex:split(repositoryName, orgRepoSeparator)[1];
    return repositoryNameWithoutOrgName;
}

function createNewSheetIfRequired(string spreadsheetID, string sheetName) returns WorkSheetContext|error {
    sheets:Sheet|error sheet = spreadsheetClient->getSheetByName(spreadsheetID, sheetName);
    WorkSheetContext context = {
                 spreadSheetId: spreadsheetID,
                 worksheetName: sheetName,
                 endingColumnInDataRange: endingColumnForGSheetData
        };
    if (sheet !is sheets:Sheet) {
        _ = check spreadsheetClient->addSheet(spreadsheetID, sheetName);
        check appendSingleRowToGSheet(context, GSheetHeaderColumns);
    } else {
        //TODO: sheet exists. Clear up all data? 
    }
    return context;
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

function getClosedPRs(github:Client githubClient, string repositoryName, string startDate, string endDate) returns github:PullRequest[]|error {
    string query = constructGithubQuery(repositoryName, true, startDate, endDate);
    return extractPRInfo(githubClient, repositoryName, query);
}

function getOpenPRs(github:Client githubClient, string repositoryName, string startDate, string endDate) returns github:PullRequest[]|error {
    string query = constructGithubQuery(repositoryName, false, startDate, endDate);
    return extractPRInfo(githubClient, repositoryName, query);
}

function getDateRangeForPreviousMonth() returns string {
    time:Civil timeNow = time:utcToCivil(time:utcNow());
    int yearToQuery = timeNow.year;
    int monthToQuery = timeNow.month - 1;   //previous month
    if(monthToQuery == 0) {     //adjust for year end
        monthToQuery = 12;
        yearToQuery = yearToQuery - 1;
    }
    int endingDateForMonth = getNumberOfDaysForMonth(yearToQuery, monthToQuery);
    return constructDateRange(yearToQuery, monthToQuery, endingDateForMonth);
}

function constructDateRange(int yearToQuery, int monthToQuery, int endingDateForMonth) returns string {
    //Specify the date range in format YYYY-MM-DD:YYYY-MM-DD (start date: end date)
    string sanitizedMonthNum;
    if monthToQuery < 10 {
        sanitizedMonthNum = string `0${monthToQuery}`;
    } else {
        sanitizedMonthNum = monthToQuery.toString();
    }
    return string `${yearToQuery}-${sanitizedMonthNum}-01:${yearToQuery}-${sanitizedMonthNum}-${endingDateForMonth}`;
}

function getNumberOfDaysForMonth(int year, int month) returns int {
    if(month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
        return 31;
    } else if((month == 2) && ((year%400==0) || (year%4==0 && year%100!=0))) {
        return 29;
    } else if(month == 2) {
        return 28;
    } else {
        return 30;
    }
}

function constructSheetName(string startDate) returns string|error {
    //format YYYY-MM-DD
    string year = regex:split(startDate, "-")[0];
    string month = regex:split(startDate, "-")[1];
    int monthAsNumber = check int:fromString(month);
    string monthAsString =  monthsOfYear[monthAsNumber - 1];
    return string `${monthAsString} ${year}`;
}

function getMembersApprovedPR(github:PullRequest pullRequest, map<string> teamMembers) returns string|error {
    string membersApprovedPR = "";
    github:PullRequestReview[]? PRReviews = pullRequest.pullRequestReviews;
    if PRReviews is github:PullRequestReview[] {
        foreach github:PullRequestReview review in  PRReviews {
            if review.state == github:PR_REVIEW_APPROVED {
                github:Actor? PRApprovedBy = review?.author;
                if PRApprovedBy is github:Actor {
                    string githubNameOfMember = PRApprovedBy.login;
                    string? emailOfMember = teamMembers[githubNameOfMember];
                    if emailOfMember is string {
                        membersApprovedPR = PRApprovedBy.login + "(" + emailOfMember + ")" + ", ";
                    } else {
                        membersApprovedPR = PRApprovedBy.login + ", ";
                    }        
                } 
            }
        }
    }
    int? indexOfLastComma = string:lastIndexOf(str = membersApprovedPR, substr = ",");
    if(indexOfLastComma is int) {
        membersApprovedPR = membersApprovedPR.substring(0,indexOfLastComma);
    }
    return membersApprovedPR;
}

//first tab in the worksheet will contain the repository list
function getRepositoryList(string worksheetId, string sheetName, string column) returns string[]|error {   
    sheets:Column columnInfo = check spreadsheetClient->getColumn(worksheetId, sheetName, column);  
    return from (string|int|decimal) repoData in columnInfo.values 
                where repoData is string 
                select repoData;
}

function populateMemberInfo(string worksheetId, string sheetName, string range) returns map<string>|error {
    sheets:Range gSheetResult = check spreadsheetClient->getRange(worksheetId, sheetName, range);
    (int|string|decimal)[][] values = gSheetResult.values;
    map<string> teamMebers = {}; 
    foreach ((int|string|decimal)[]) entry in values {
        string githubUsername = check entry[0].ensureType();
        string email = check entry[1].ensureType();
        teamMebers[githubUsername] = email;
    }
    return teamMebers;
}

function getPRAuthor(github:PullRequest pullRequest, map<string> teamMembers) returns [string, string] {
    github:Actor? PRAuthorAtGithub = pullRequest?.author;
    string PRAuthorGitHubId = "Unknown User";
    string PRAuthorEmail = "Unknown Email";
    if PRAuthorAtGithub is github:Actor {
        PRAuthorGitHubId = PRAuthorAtGithub.login;
        string? PRAuthorEmailFound = teamMembers[PRAuthorGitHubId];
        if PRAuthorEmailFound is string {
            PRAuthorEmail = PRAuthorEmailFound;
        }
    }
    return [PRAuthorGitHubId, PRAuthorEmail];
}

function getDatesBetween(string createdAt, string closedAt) returns int|error {
    int numOfDatesBetweenCreateAndClose = 0;
    if (closedAt != "") {
        time:Utc createdAtUtc = check time:utcFromString(createdAt);
        time:Utc closedAtUtc = check time:utcFromString(closedAt);
        numOfDatesBetweenCreateAndClose = <int>((time:utcDiffSeconds(createdAtUtc, closedAtUtc)).abs() / (60 * 60 * 24));
    } else {
        time:Utc createdAtUtc = check time:utcFromString(createdAt);
        numOfDatesBetweenCreateAndClose = <int>((time:utcDiffSeconds(createdAtUtc, time:utcNow())).abs() / (60 * 60 * 24)); //number of days since created
    }
    return numOfDatesBetweenCreateAndClose;
}

function checkIfPRIsFromTeam(github:PullRequest pullRequest, map<string> teamMembers) returns boolean {
    string PRSentBy = pullRequest?.author is github:Actor ? (<github:Actor>pullRequest?.author).login : "Unknown User";
    if PRSentBy == "Unknown User" {
        return false;
    } else {
        return teamMembers.hasKey(PRSentBy);
    }
}
