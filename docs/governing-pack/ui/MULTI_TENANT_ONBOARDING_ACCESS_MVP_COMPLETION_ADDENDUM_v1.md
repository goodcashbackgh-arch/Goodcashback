# Multi-Tenant Onboarding & Access MVP — Completion Addendum v1

## Purpose

This addendum freezes the remaining completion work for `MULTI_TENANT_ONBOARDING_ACCESS_MVP_CONTRACT_v1` after rechecking the current repository and live database on 16 August 2026.

It does **not** replace the existing contract. It narrows the remaining work and adds explicit no-break rules for existing users and working platform flows.

The implementation must finish the existing additive access/onboarding architecture. It must not create a parallel user system or migrate existing users to new identities.

---

## 1. Verified baseline

The access foundation is already built and existing users were already backfilled into it.

Verified live preflight:

```text
active legacy login records = 8
legacy users missing platform profile = 0
expected memberships missing = 0
supervisors missing scope = 0
portal membership orphans = 0
existing-user backfill parity = clean
```

Three active legacy/profile auth IDs do not resolve in `auth.users`, but the identified records are test fixtures:

```text
Test Staff
Test Operator Flow
Browser DVA Test Operator
```

These test records must not be used as justification to recreate, migrate, disable, or otherwise alter genuine existing users.

The existing working login identities and auth IDs remain authoritative.

---

## 2. Existing-user protection — locked rule

Existing users must remain on their current identities.

Do not:

```text
create replacement auth users for existing users
change existing auth_user_id values
bulk rewrite existing memberships
bulk change passwords
bulk disable users
move users into a parallel onboarding path
remove legacy fallback before new routing is proven
```

The new access layer must continue to sit around the existing records:

```text
staff
shipper_users
operators
operator_importers
platform_user_profiles
platform_user_memberships
```

Existing admin, supervisor, shipper and operator/customer/importer users must continue to log in during and after each patch.

If new membership routing fails or encounters an incomplete record, the existing legacy routing fallback must remain available until acceptance testing is complete.

---

## 3. Customer / Importer / Both — completion rule

The existing membership model is retained.

For a customer/importer user, admin may grant exactly:

```text
Customer only
Importer only
Customer + Importer
```

No new role model is required.

### Role update behaviour

Changing the selected roles must update the user's active `customer` / `importer` memberships for the target importer branch.

Example:

```text
Before: Customer + Importer
Admin saves: Customer only
After: Customer active, Importer revoked
```

Unticking a role must not leave the old role active.

Role replacement must be limited to the customer/importer memberships being edited. It must not alter unrelated staff, shipper, supervisor, or other-branch memberships.

All membership changes must remain auditable.

---

## 4. Login routing and portal enforcement

Finish the existing membership-based routing on the same login identities.

Required routing:

```text
admin                 → /internal
supervisor            → /internal
shipper-only          → /shipper
customer-only         → /customer
importer-only         → /importer
customer + importer   → /workspace/select
```

`must_change_password = true` continues to take priority and routes to the existing/planned password-change flow.

### Enforcement rule

Portal access must be checked server-side from the same resolved user/access context used for routing.

A customer-only membership must not obtain importer access merely because an `operators` or `operator_importers` record exists.

An importer-only membership must not obtain customer access merely because the same legacy operator record exists.

### Transition rule

Do not remove legacy fallback in the same step that introduces the new resolver.

Build and prove the new resolver first, compare it against current working users, then enable membership enforcement while retaining an immediate rollback/fallback path.

---

## 5. Admin-created user onboarding — locked rule

There is no public signup requirement.

Admin performs the onboarding.

For a new customer/importer user the controlled flow is:

```text
1. Create auth login.
2. Create/update platform_user_profile.
3. Create operator record.
4. Link operator to the selected importer/customer branch.
5. Create the selected Customer / Importer memberships.
6. Set temporary password.
7. Set must_change_password = true.
8. Present the login details to admin once for delivery to the user.
9. User changes password on first login.
```

The user does not choose their own branch, country, roles, or initial permissions.

The platform must not store a plaintext temporary password.

### Failure safety

The onboarding operation must not leave a half-configured login that appears ready.

If auth-user creation succeeds but a later platform step fails, the flow must either compensate safely or mark the user clearly incomplete and unusable until repaired.

Do not silently leave a login with missing operator/importer/membership records.

---

## 6. Branch → country locking — completion rule

The original one-country-per-branch contract remains locked.

Admin selects the shipping-company branch for a customer/importer.

The system derives the country from that branch.

Admin must not independently choose a conflicting customer/importer country after the branch is selected.

Required server-side control:

```text
selected importer/customer branch shipper_id
→ resolve exactly one active shipper_countries country
→ importer/customer country_id must equal that country
```

A branch with zero countries or multiple countries is not ready for new onboarding.

### Existing data protection

The live preflight identified three active test branches with no `shipper_countries` row and two related importer/branch-country issues. These are test fixtures.

Do not bulk rewrite existing production branches/importers as part of this patch.

The guard applies to new/edited onboarding writes. Existing anomalies are reviewed separately before any corrective data write.

---

## 7. Retailer-account readiness — completion rule

Keep the existing retailer and retailer-account model.

Do not create a replacement account model.

Existing components remain authoritative:

```text
retailers
shipper_retailers
retailer_accounts
```

The onboarding/access area must allow staff to create or maintain the retailer account required for the selected shipper + retailer operational lane.

### Deterministic account rule

For the current order/invoice workflow, a shipper + retailer lane must resolve to exactly one active retailer account when that retailer account is required downstream.

The current live preflight shows:

```text
duplicate active retailer+shipper pairs = 0
```

A database guard may be added only if it matches the existing resolver's one-active-account requirement and existing data passes the preflight first.

Do not bulk create retailer accounts for every enabled retailer.

An enabled retailer without a real account is not automatically a data defect; test and unused retailer pairs may legitimately have no account.

### Readiness enforcement

Before changing the order retailer list globally, classify existing operational retailer+shipper pairs and ensure required accounts exist.

New onboarding must not present a retailer lane as fully operational if the later invoice flow would fail because no deterministic active account exists.

This avoids breaking current users while closing the configuration gap for future onboarding.

---

## 8. Sage mapping — no rebuild

The existing Sage party-mapping implementation is retained.

Supported process remains:

```text
Create/confirm customer or supplier in Sage.
Select or enter the Sage contact ID in the existing Sage mapping control.
Map it to the platform importer/customer/retailer/shipper party.
```

No new Sage contact-creation system is required for this completion scope.

Onboarding may link to or surface the existing Sage mapping control for convenience, but must not duplicate Sage mapping logic.

---

## 9. Safe implementation order

The remaining work must be delivered in isolated, reversible patches.

### Patch A — shared access resolver

```text
add one shared server-side resolver
read existing profile + memberships
preserve legacy fallback
no existing-user data rewrite
no enforcement switch yet
```

Prove current existing users resolve to their expected workspaces before proceeding.

### Patch B — role update semantics

```text
make Customer / Importer / Both updates exact
revoke unticked customer/importer membership safely
leave unrelated memberships untouched
audit before/after state
```

### Patch C — admin-created login onboarding

```text
create new auth login
create existing platform/operator/link records
apply selected membership(s)
temporary password
must-change-password flag
failure compensation/incomplete-state protection
```

This patch is for newly onboarded users. It does not recreate existing users.

### Patch D — branch/country server guard

```text
derive country from branch
reject zero/multiple-country branch for new onboarding
reject branch/importer country mismatch
no bulk historical correction
```

### Patch E — retailer-account onboarding/readiness

```text
reuse retailer_accounts
add create/edit management to onboarding/access control
prove no duplicate active production pair
add deterministic-account protection where required
classify existing operational pairs before global order-list gating
```

### Patch F — routing and portal enforcement

```text
customer-only → customer
importer-only → importer
both → workspace selector
staff/shipper routing unchanged in intent
server-side portal guards use same resolver
legacy fallback retained for rollback during acceptance
```

### Patch G — acceptance and enforcement

Only after regression tests pass:

```text
enable final membership routing/enforcement
retain immediate fallback/rollback capability for first release
```

---

## 10. Mandatory no-break regression pack

Before final enforcement, prove all of the following against the current working platform:

```text
existing admin login still works
existing staff/supervisor login still works
existing shipper login still works
existing operator/importer login still works
existing dual-role user retains both intended roles
customer-only user cannot enter importer portal
importer-only user cannot enter customer portal
changing Both → Customer revokes only Importer role
changing Both → Importer revokes only Customer role
new admin-created user can log in with temporary credentials
new user is forced to change password
new user retains the same auth identity after password change
branch determines country for new onboarding
mismatched country write is rejected
existing historical branch/importer records are not bulk changed
existing retailer accounts remain untouched
new duplicate active retailer-account state is rejected if deterministic one-account guard is enabled
configured retailer proceeds through order → invoice path
unconfigured new retailer lane is not presented as operationally ready
existing order lifecycle still works
existing payment/DVA matching still works
existing shipment/package flow still works
existing evidence/review flow still works
existing accounting/VAT/Sage posting flow still works
```

---

## 11. Scope exclusions

This completion patch must not expand into:

```text
public signup
email invitation system
new customer table
new operator model
new retailer-account model
new Sage integration
multi-country shipper branch support
broad RLS rewrite
accounting/VAT refactor
order lifecycle refactor
shipping workflow refactor
historical data cleanup unrelated to the identified onboarding controls
```

---

## Final locked completion scope

Finish the existing onboarding/access architecture in place.

Existing users keep their current auth identities and working access while the new membership resolver is proven. Admin creates future user logins, assigns the existing importer/customer branch, selects Customer / Importer / Both, supplies temporary login details, and the user changes the password on first login. Branch determines country. Retailer-account configuration becomes deterministic and onboarding-ready without bulk-altering existing retailer pairs. Existing Sage mapping is reused unchanged.

No parallel user path. No rebuild of working platform flows. No enforcement change without parity and regression proof.
