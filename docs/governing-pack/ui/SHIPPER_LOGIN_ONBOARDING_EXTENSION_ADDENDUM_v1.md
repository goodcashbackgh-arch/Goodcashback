# Shipper Login Onboarding Extension Addendum v1

## Purpose
Add staff-created Shipper logins to the existing multi-tenant onboarding centre without changing the proven Customer/Importer onboarding path.

## Frozen surgical design
- Existing `createNewOperatorOnboardingAction` and `internal_create_operator_onboarding_v1` remain unchanged.
- Existing Customer/Importer role semantics remain unchanged.
- Add an isolated Shipper-login form as a sibling surface in `/internal/onboarding`.
- Add one sibling server action and one sibling database writer.
- Reuse existing Supabase Auth creation, temporary-password pattern, `platform_user_profiles`, `must_change_password`, password-change completion, shared resolver and `/shipper` routing.
- A usable Shipper login MUST have both the canonical `shipper_users` row and exactly one matching active `platform_user_memberships` row.

## Shipper login inputs
- Full name
- Email
- Phone (optional)
- Active shipper branch
- Exactly one access level: `shipper_admin`, `shipper_operator`, or `shipper_readonly`
- Default UI access level: `shipper_operator`

## Database writer contract
`internal_create_shipper_user_onboarding_v1(...)` must:
1. require an active staff actor;
2. validate the live schema shape before installation;
3. validate active shipper branch and allowed shipper role;
4. reject identity/email collisions across existing platform identities;
5. create `platform_user_profiles` with `must_change_password = true`;
6. create the canonical `shipper_users` row;
7. create exactly one matching shipper membership;
8. write `shipper_user_onboarding_created` to `platform_access_audit_log`;
9. perform its database writes atomically.

## Auth compensation
The sibling server action must use the existing proven pattern: create the Auth user first, call the atomic database writer, and delete the newly created Auth user if the database writer fails. If deletion fails, replace the password with an undisclosed random password and ban the incomplete Auth user.

## No-break exclusions
Do NOT modify:
- `internal_create_operator_onboarding_v1`
- `internal_set_operator_importer_roles_v1`
- existing Customer/Importer form fields or semantics
- existing Auth identities or `auth_user_id` values
- existing `shipper_users` rows
- shared resolver or `/auth/check`
- password-change flow
- Customer/Importer/Shipper operational workflows
- accounting, VAT, Sage, shipment, evidence, DVA/payment logic
- historical data/backfills

## Acceptance
Before merge:
- migration built-in schema guard passes;
- postflight reports ready with no existing-user parity defects;
- create one disposable Shipper login from Internal Onboarding;
- temporary password is shown once;
- first login is forced to change password;
- same Auth identity lands on `/shipper` after password change;
- selected shipper branch is correct;
- exactly one selected shipper role exists;
- existing Customer/Importer login creation remains operational and unchanged;
- existing admin, shipper, importer/customer access is not regressed.
