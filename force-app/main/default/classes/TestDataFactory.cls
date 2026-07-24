/**
 * Shared test-data builder for the Case resolution-time feature.
 *
 * Marked @isTest so it does not count toward org Apex code or coverage.
 *
 * NOTE ON DATES: Case.CreatedDate and Case.ClosedDate are createable=false,
 * updateable=false (research-spec C2) and cannot be assigned. Age a Case with
 * Test.setCreatedDate(id, dt); obtain ClosedDate by updating Status. Numeric, boundary and
 * negative durations are unit-tested directly against
 * CaseResolutionService.calculateResolutionDays with literal Datetime arguments.
 *
 * See technical-spec.md section 6.0.
 */
@isTest
public class TestDataFactory {
    public static final String OPEN_STATUS = 'New';
    public static final String WORKING_STATUS = 'Working';
    public static final String CLOSED_STATUS = 'Closed';
    public static final String PERMISSION_SET_NAME = 'CaseResolutionMetrics_Read';

    private static Integer userCounter = 0;

    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(Name = 'Test Account ' + i));
        }
        if (doInsert) {
            insert accounts;
        }
        return accounts;
    }

    public static List<Case> createCases(Id accountId, Integer count, Boolean doInsert) {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < count; i++) {
            cases.add(
                new Case(
                    AccountId = accountId,
                    Subject = 'Test Case ' + i,
                    Status = OPEN_STATUS,
                    Origin = 'Phone'
                )
            );
        }
        if (doInsert) {
            insert cases;
        }
        return cases;
    }

    /**
     * A user with the 'Minimum Access - Salesforce' profile and no permission sets.
     *
     * MUST be called inside System.runAs(new User(Id = UserInfo.getUserId())) when the test
     * also performs Account/Case DML, otherwise the User insert raises
     * MIXED_DML_OPERATION.
     */
    public static User createMinimumAccessUser() {
        return createUserOnProfile('Minimum Access - Salesforce');
    }

    /**
     * A user on the 'Standard User' profile, which grants Read+Edit on Case and Account
     * (verified 2026-07-23 by querying ObjectPermissions) but NO field-level access to the
     * four new custom fields.
     *
     * This is the correct subject for an FLS test. A 'Minimum Access - Salesforce' user has
     * no object permission on Case or Account at all, so Field.isAccessible() is false for
     * them however the permission set is configured - field access requires object access
     * first. Since CaseResolutionMetrics_Read deliberately grants no objectPermissions
     * (D5a, least privilege), only a user with pre-existing object access can demonstrate
     * that the permission set is what turns field read on.
     *
     * Same MIXED_DML_OPERATION caveat as createMinimumAccessUser().
     */
    public static User createStandardUser() {
        return createUserOnProfile('Standard User');
    }

    private static User createUserOnProfile(String profileName) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        userCounter++;
        String uniqueSuffix = String.valueOf(UserInfo.getOrganizationId())
            + String.valueOf(userCounter)
            + String.valueOf(Datetime.now().getTime());
        User minUser = new User(
            ProfileId = targetProfile.Id,
            LastName = 'MinAccess',
            Alias = 'minacc',
            Email = 'case.metrics.test@example.invalid',
            Username = 'case.metrics.' + uniqueSuffix + '@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        insert minUser;
        return minUser;
    }

    public static void assignPermissionSet(Id userId, String permSetName) {
        PermissionSet permSet = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permSet.Id);
    }
}
