/**
 * Permission / negative test for the four derived fields.
 *
 * Required by .claude/rules/security.md. Proves AC8 / D5c: with the permission set a user
 * can READ all four fields and can UPDATE none of them; without it, none are accessible.
 *
 * See technical-spec.md section 6.7.
 */
@isTest
private class CaseResolutionMetricsSecurityTest {
    @isTest
    static void withoutThePermissionSetNoneOfTheFieldsAreAccessible() {
        User minUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            minUser = TestDataFactory.createMinimumAccessUser();
        }

        Test.startTest();
        System.runAs(minUser) {
            Assert.isFalse(
                Schema.SObjectType.Case.fields.Resolution_Time_Days__c.isAccessible(),
                'Case.Resolution_Time_Days__c must not be readable without the permission set.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Closed_Case_Count__c.isAccessible(),
                'Account.Closed_Case_Count__c must not be readable without the permission set.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Average_Resolution_Time_Days__c.isAccessible(),
                'Account.Average_Resolution_Time_Days__c must not be readable without the '
                    + 'permission set.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Case_Metrics_Last_Calculated__c.isAccessible(),
                'Account.Case_Metrics_Last_Calculated__c must not be readable without the '
                    + 'permission set.'
            );
        }
        Test.stopTest();
    }

    @isTest
    static void withoutThePermissionSetAUserWithObjectAccessStillCannotSeeTheFields() {
        // Isolates FLS from CRUD: this user HAS Case and Account access, so the only thing
        // that can be denying the four fields is the absence of the permission set.
        User standardUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            standardUser = TestDataFactory.createStandardUser();
        }

        Test.startTest();
        System.runAs(standardUser) {
            Assert.isTrue(
                Schema.SObjectType.Case.isAccessible(),
                'Precondition: this user must have Case object access, otherwise the test '
                    + 'would prove nothing about FLS.'
            );
            Assert.isFalse(
                Schema.SObjectType.Case.fields.Resolution_Time_Days__c.isAccessible(),
                'Object access alone must not expose the derived field - FLS is required.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Closed_Case_Count__c.isAccessible(),
                'Object access alone must not expose Closed_Case_Count__c.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Average_Resolution_Time_Days__c.isAccessible(),
                'Object access alone must not expose Average_Resolution_Time_Days__c.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Case_Metrics_Last_Calculated__c.isAccessible(),
                'Object access alone must not expose Case_Metrics_Last_Calculated__c.'
            );
        }
        Test.stopTest();
    }

    @isTest
    static void withThePermissionSetFieldsAreReadableButNeverUpdateable() {
        // NOTE FOR REVIEWERS - technical-spec 6.7 specifies a "minimum-access user" here,
        // but that assertion cannot pass and the spec contradicts itself: 2.2 deliberately
        // grants NO objectPermissions (D5a, least privilege), and the
        // 'Minimum Access - Salesforce' profile has no Case or Account object permission at
        // all (verified 2026-07-23 via ObjectPermissions). Field.isAccessible() is false
        // whenever object access is missing, regardless of FLS - so no permission set that
        // grants field access only could ever make it true for that profile.
        //
        // The subject is therefore a 'Standard User' (Case + Account Read/Edit, but NO FLS
        // on the four new fields, since no profile was edited). That isolates the permission
        // set as the sole cause of field readability, which is exactly what AC8 asserts. The
        // negative case for a truly minimum-access user is covered by the test above.
        User standardUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            standardUser = TestDataFactory.createStandardUser();
            TestDataFactory.assignPermissionSet(
                standardUser.Id,
                TestDataFactory.PERMISSION_SET_NAME
            );
        }

        Test.startTest();
        System.runAs(standardUser) {
            Assert.isTrue(
                Schema.SObjectType.Case.fields.Resolution_Time_Days__c.isAccessible(),
                'Case.Resolution_Time_Days__c must be readable with the permission set.'
            );
            Assert.isTrue(
                Schema.SObjectType.Account.fields.Closed_Case_Count__c.isAccessible(),
                'Account.Closed_Case_Count__c must be readable with the permission set.'
            );
            Assert.isTrue(
                Schema.SObjectType.Account.fields.Average_Resolution_Time_Days__c.isAccessible(),
                'Account.Average_Resolution_Time_Days__c must be readable with the '
                    + 'permission set.'
            );
            Assert.isTrue(
                Schema.SObjectType.Account.fields.Case_Metrics_Last_Calculated__c.isAccessible(),
                'Account.Case_Metrics_Last_Calculated__c must be readable with the '
                    + 'permission set.'
            );

            // These four assertions are what prove a derived value cannot be hand-edited.
            Assert.isFalse(
                Schema.SObjectType.Case.fields.Resolution_Time_Days__c.isUpdateable(),
                'Case.Resolution_Time_Days__c is derived and must never be user-writable.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Closed_Case_Count__c.isUpdateable(),
                'Account.Closed_Case_Count__c is derived and must never be user-writable.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Average_Resolution_Time_Days__c.isUpdateable(),
                'Account.Average_Resolution_Time_Days__c is derived and must never be '
                    + 'user-writable.'
            );
            Assert.isFalse(
                Schema.SObjectType.Account.fields.Case_Metrics_Last_Calculated__c.isUpdateable(),
                'Account.Case_Metrics_Last_Calculated__c is derived and must never be '
                    + 'user-writable.'
            );
        }
        Test.stopTest();
    }

    @isTest
    static void thePermissionSetGrantsNoObjectOrApexAccess() {
        // Least privilege: the set exists purely to expose four read-only fields.
        PermissionSet permSet = [
            SELECT Id,
                (SELECT Id FROM ObjectPerms),
                (SELECT Id FROM SetupEntityAccessItems),
                (SELECT Id, Field, PermissionsRead, PermissionsEdit FROM FieldPerms)
            FROM PermissionSet
            WHERE Name = :TestDataFactory.PERMISSION_SET_NAME
            LIMIT 1
        ];

        Assert.areEqual(
            0,
            permSet.ObjectPerms.size(),
            'The permission set must grant no object permissions - agents already have Case '
                + 'and Account access.'
        );
        Assert.areEqual(
            0,
            permSet.SetupEntityAccessItems.size(),
            'The permission set must grant no Apex class or other setup entity access.'
        );
        Assert.areEqual(
            4,
            permSet.FieldPerms.size(),
            'Exactly the four derived fields, and nothing else.'
        );
        for (FieldPermissions fieldPerm : permSet.FieldPerms) {
            Assert.isTrue(
                fieldPerm.PermissionsRead,
                fieldPerm.Field + ' must be readable.'
            );
            Assert.isFalse(
                fieldPerm.PermissionsEdit,
                fieldPerm.Field + ' must be read-only (D5c).'
            );
        }
    }
}
