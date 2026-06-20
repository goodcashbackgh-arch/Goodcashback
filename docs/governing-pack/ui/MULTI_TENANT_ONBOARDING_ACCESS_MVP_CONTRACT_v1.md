# Multi-Tenant Onboarding, Access, FX, and Branch Control — MVP Contract v1

## Purpose

This contract defines the minimum production-level build required to make the platform safely multi-tenant without breaking the existing order, payment, shipping, accounting, VAT, and document workflows.

The MVP must wrap and enforce the existing platform foundations. It must not rebuild the working order lifecycle.

The existing platform already has the core country, currency, shipper, importer, operator, shipper-user, and FX foundations. The MVP introduces controlled onboarding, branch assignment, password handling, supervisor scope, and branch-safe access.

---

## 1. Locked Branch Rule

### MVP rule

One onboarded shipping-company branch equals one country, jurisdiction, and currency lane.

Allowed:

```text
Ghana
  - Shipper A Ghana
  - Shipper B Ghana
  - Shipper C Ghana
```

Also allowed:

```text
Nigeria
  - Shipper A Nigeria
  - Shipper D Nigeria
```

Not allowed inside one branch for MVP:

```text
Shipper A
  - Ghana
  - Nigeria
  - Sierra Leone
```

If the same real-world shipping company serves a second country, onboard it again as a separate branch:

```text
Shipper A Ghana
Shipper A Nigeria
```

### Reason

This is the simplest robust structure. It prevents confusion across currency, FX rates, hubs, customer/importer lanes, statement matching, supervisor visibility, shipper users, shipping evidence, and order dashboards.

The platform may later support a single shipper serving multiple countries inside one branch, but that is not MVP.

---

## 2. MVP Hierarchy

```text
ADMIN
  └── Shipping-company branch
        ├── One country / currency lane
        ├── Hubs for that branch
        ├── Enabled retailers for that branch
        ├── Shipper users for that branch
        ├── Customer/importer branches
        └── Orders / payments / statements / shipping / documents
```

Supervisor sits across branches:

```text
Supervisor
  - mode: all branches
  - or mode: assigned branches only
```

Admin sees everything.

---

## 3. Core Assignment Principle

### Correct rule

Customer/importer is assigned to a specific shipping-company branch.

The shipping-company branch determines the country and currency lane.

Therefore:

```text
Customer/importer does not select country directly during order creation.
Customer/importer does not select shipper directly during order creation.
Customer/importer inherits the assigned branch.
The assigned branch controls hubs, retailers, FX country, currency, and shipper lane.
```

### Correct hub rule

Order forms must show only hubs belonging to the customer/importer’s assigned shipping-company branch:

```text
hubs.shipper_id = importer.shipper_id
hubs.active = true
```

The system must not show hubs merely because they are in the same country.

Country consistency is enforced during onboarding/configuration:

```text
branch country = hub country
branch country = importer/customer country
importer/customer shipper_id = branch shipper_id
```

Country remains a control, but the operational selector is the shipping-company branch.

---

## 4. What MVP Must Support

### Admin must be able to create and manage

```text
shipping-company branch
country for that branch
hub for that branch
enabled retailers for that branch
customer/importer under that branch
customer/importer user
shipper user
supervisor
supervisor branch assignment
temporary password reset
disable/reactivate user
```

### Supervisor must be able to

```text
see all branches if set to all mode
see assigned branches only if set to assigned mode
view/manage users under visible branches
reset passwords only for users under visible branches
maintain daily FX rates
operate assigned supervisor workbenches
```

### Shipper user must be able to

```text
see only own shipping-company branch
handle shipment/package/evidence work for own branch
not see funding
not see FX
not see accounting
not see VAT
not see other shippers
```

### Customer/importer user must be able to

```text
see only own customer/importer branch
create orders under own assigned shipping-company branch
use the correct branch country/currency FX rate
upload order evidence
upload tracking
not see other customers/importers
```

---

## 5. MVP Build Components

### Add access-control tables only

Add:

```text
platform_user_profiles
platform_user_memberships
supervisor_access_scopes
supervisor_branch_assignments
platform_access_audit_log
```

Do not rewrite existing role tables.

Do not remove:

```text
staff
operators
operator_importers
shipper_users
shippers
importers
shipper_countries
hubs
shipper_retailers
```

These existing tables remain part of the working platform.

---

### platform_user_profiles

```text
id
auth_user_id
email
display_name
active
must_change_password
created_by_staff_id
created_at
disabled_at
disabled_by_staff_id
```

Purpose:

```text
one central profile per login identity
password-change control
active/disabled control
admin/supervisor reset control
```

---

### platform_user_memberships

```text
id
auth_user_id
role_code
shipper_id
importer_id
staff_id
active
created_at
revoked_at
```

Allowed `role_code`:

```text
admin
supervisor
shipper_admin
shipper_operator
shipper_readonly
customer
importer
```

Rules:

```text
admin role links to staff_id
supervisor role links to staff_id
shipper roles link to shipper_id
customer/importer roles link to importer_id
```

For MVP, customer and importer may still point to the existing importer branch. A separate customer table is not required.

---

### supervisor_access_scopes

```text
id
supervisor_staff_id
scope_mode
active
created_at
updated_at
```

Allowed `scope_mode`:

```text
all
assigned
```

Rules:

```text
scope_mode = all       → supervisor can see all branches
scope_mode = assigned  → supervisor can see assigned branches only
assigned + no branches → supervisor sees no operational branch data
```

Do not treat “no assignment” as “see everything”.

---

### supervisor_branch_assignments

```text
id
supervisor_staff_id
shipper_id
active
created_at
revoked_at
```

Reason:

Each `shipper_id` is treated as one country-specific branch in MVP. If a supervisor can see that branch, they can see that branch’s importers/customers/orders.

This avoids separate shipper, importer, and customer assignment tables in MVP.

---

### platform_access_audit_log

```text
id
actor_auth_user_id
actor_staff_id
action_type
target_auth_user_id
target_shipper_id
target_importer_id
before_json
after_json
created_at
```

Audit these actions:

```text
user_created
user_disabled
user_reactivated
password_reset
membership_added
membership_revoked
supervisor_scope_changed
branch_assigned
branch_unassigned
branch_created
branch_updated
importer_created
shipper_user_created
```

---

## 6. Branch Onboarding Contract

### Admin creates shipping-company branch

Admin enters:

```text
branch name
country
primary hub
contact details
enabled retailers
shipper users
```

System creates or validates:

```text
shippers
shipper_countries
hubs
shipper_retailers
shipper_users
platform_user_profiles
platform_user_memberships
```

### Required validation

```text
branch must have exactly one country in MVP
branch must have at least one active hub
hub must belong to the branch
hub country must equal branch country
importer/customer must belong to the branch
importer/customer country must equal branch country
retailer must be enabled for the branch before order creation
daily FX rate must exist before customer/importer quote creation
```

### Important rule

When creating a customer/importer, admin selects:

```text
shipping-company branch
```

The system derives:

```text
country
currency
available hubs
available retailers
FX country
```

Admin should not independently select a mismatched country after selecting the branch.

---

## 7. FX Contract

### MVP FX rule

```text
FX is by country/date.
Currency comes from country.
Branch country determines which FX country applies.
FX must be entered before quotes or statement extraction for that country/date.
```

FX fields required:

```text
country_id
rate_date
quote_rate
quote_card_markup_pct
settlement_rate
settlement_card_markup_pct
```

### FX page wording

Use:

```text
Missing FX-rate records
```

Description:

```text
Find missing FX-rate records for the selected country/date range before quotes, statement extraction, and payment matching. This checks whether records exist; it does not validate the rate against an external source.
```

Button:

```text
Find missing rates
```

Country dropdown should display currency once multi-country production starts:

```text
Ghana (GHA) — GHS
Nigeria (NGA) — NGN
```

---

## 8. Order Creation Contract

Current order creation already uses the importer’s assigned shipper and country to obtain FX and create orders.

MVP must preserve that.

### Required order form rule

Order form must show:

```text
retailers enabled for importer.shipper_id
hubs belonging to importer.shipper_id
```

Order form must not show:

```text
hubs from other shipping-company branches
retailers from other shipping-company branches
```

### Required server-side validation

Order action must reject selected hub unless:

```text
hub.shipper_id = importer.shipper_id
hub.active = true
```

Order action should also defensively reject configuration drift where:

```text
hub.country_id does not equal importer.country_id
```

But the primary access filter remains shipper branch, not country.

### Required FX validation

Order creation must block if no FX rate exists for the importer’s branch country:

```text
fx_rates.country_id = importer.country_id
rate_date <= order quote date
latest rate used
```

---

## 9. Local Currency Fields

Current order creation stores local quote value in a Ghana-specific field name.

MVP rule:

Do not rename or remove the existing field yet.

Add generic fields:

```text
quote_currency_code
quote_total_local
```

Keep the existing Ghana-specific field populated for backward compatibility until later cleanup.

This avoids breaking existing downstream logic.

---

## 10. Login and Workspace Contract

Current login routing is priority-based. MVP needs membership-based routing.

### MVP routing

```text
No user
  → /login

must_change_password = true
  → /account/change-password

admin
  → /internal

supervisor
  → /internal

shipper-only user
  → /shipper

customer-only user
  → /customer

importer-only user
  → /importer

customer + importer
  → /workspace/select
```

### Workspace selector

Only needed for multiple non-staff workspaces.

Do not give admin/supervisor a selector in MVP.

Admin and supervisor are privileged roles and should route directly to internal.

---

## 11. Password Contract

No email dependency in MVP.

### Admin reset

Admin can reset any user.

Resetting another admin should require explicit confirmation.

### Supervisor reset

Supervisor can reset only users under branches they can see.

Supervisor cannot reset:

```text
admin
other supervisor
users outside visible branch
```

### Reset behaviour

```text
generate temporary password
set must_change_password = true
show temporary password once
do not store plaintext password
write audit log
```

---

## 12. Existing Login Protection Contract

This build must not break existing logins.

### Current login protection principle

The current working login sources remain valid until the new access layer is fully backfilled and verified:

```text
staff
shipper_users
operators
operator_importers
```

The new access tables are additive first. They must not immediately replace current login routing.

### Backfill-before-enforce rule

Before changing `/auth/check`, run a backfill that creates profiles and memberships for every existing active user in:

```text
staff.auth_user_id
shipper_users.auth_user_id
operators.auth_user_id
```

Backfill must create memberships from:

```text
staff.role_type
shipper_users.role_at_shipper
operator_importers.importer_id
```

Existing supervisors must default to:

```text
scope_mode = all
```

This preserves current internal visibility until branch scoping is deliberately switched on.

### Fallback routing rule

The first version of membership-based `/auth/check` must keep fallback logic:

```text
if platform profile/memberships exist:
  use new routing
else:
  use legacy staff → shipper_users → operators routing
```

This prevents lockout if a user was missed by backfill.

### Enforcement switch rule

Do not hard-enforce the new access layer until diagnostics prove:

```text
every current active staff user has a platform profile and membership
every current active shipper user has a platform profile and membership
every current active operator user has a platform profile and membership
every current supervisor has scope_mode set
every current operator_importers link has a corresponding importer/customer membership where needed
```

Implementation may use an environment flag, for example:

```text
PLATFORM_ACCESS_ENFORCEMENT_ENABLED=false
```

Until this is enabled, missing platform access rows should fall back to legacy routing instead of blocking login.

### Do-not-lockout rule

The build must never create a deployment where:

```text
existing admin cannot log in
existing supervisor cannot log in
existing shipper user cannot log in
existing importer/operator cannot log in
```

If the access diagnostic detects missing profiles or memberships, the build must show warnings to admin rather than deny access.

### Rollback rule

If new auth routing behaves unexpectedly, set enforcement off and revert to legacy routing without reverting the additive tables.

---

## 13. Dashboard Contract

The FX page belongs in the payment statement workflow because FX comes before:

```text
quote generation
statement extraction
payment matching
FX/card residual review
```

The internal dashboard must include:

```text
Daily FX rates
/internal/fx-rates
```

Next MVP dashboard card needed only after page exists:

```text
Access control / onboarding
/internal/access-control
```

Do not add dead links.

---

## 14. Deliberately Out of MVP

These are not MVP:

```text
public signup
email invites
email password reset
shipper self-onboarding
shipper admin managing their own users
one shipping-company branch serving multiple countries
full RLS rewrite
scoping every historical/diagnostic internal page
renaming old local-currency fields everywhere
external FX validation API
automated FX import
customer table split
complex tenant branding/domain setup
custom domains
tenant-specific email sending
multi-country branch support
```

---

## 15. Safe Build Order

### Build 1 — schema/access foundation

```text
add access tables
backfill existing staff, operators, shipper users, operator_importers
default existing supervisors to scope_mode = all
no live behaviour change
```

This must not alter existing login routing yet.

### Build 2 — access diagnostic

Before write actions, create a read-only diagnostic in `/internal/access-control` or a temporary admin diagnostics section.

It must show:

```text
legacy users found
platform profiles created
memberships created
missing auth_user_id records
supervisor scope status
branch assignment status
fallback users still relying on legacy routing
```

No user creation or reset actions should be enabled until diagnostics show safe backfill.

### Build 3 — admin access-control page

Create:

```text
/internal/access-control
```

Admin only.

Read/manage:

```text
branches
countries
hubs
enabled retailers
users
memberships
supervisor scopes
branch assignments
password reset
disable/reactivate
```

### Build 4 — branch onboarding workflow

Admin can create:

```text
country-specific shipping-company branch
hub for that branch
enabled retailers
shipper users
customer/importer branch
customer/importer login user
```

All branch/country/currency consistency checks happen here.

### Build 5 — password flow

Create:

```text
/account/change-password
```

Enforce before portal access only after profile backfill has been verified.

### Build 6 — membership-based auth check

Replace priority routing with profile/membership routing.

Keep fallback to existing tables during transition to avoid lockout.

No existing user should lose access because their new profile was not backfilled.

### Build 7 — workspace selector

Create:

```text
/workspace/select
```

Only for customer + importer or future multi-workspace non-staff users.

### Build 8 — branch-safe order creation

Patch order creation so:

```text
hubs are filtered by importer.shipper_id
hubs from other branches are never shown
server action rejects wrong-branch hub
server action defensively rejects hub/importer country mismatch
generic local currency fields are populated
legacy local-currency field remains populated
```

### Build 9 — supervisor branch scoping

Scope only core MVP surfaces:

```text
/internal/supervisor-command-centre
/internal/dva-reconciliation/workspace
/internal/funding
/internal/evidence
/internal/invoice-review
/internal/shipping-control
/internal/access-control
```

Do not touch VAT/accounting posting lanes beyond current admin/permission gates.

---

## 16. No-Break Guardrails

The MVP must not:

```text
drop existing tables
rename existing columns
remove existing RLS policies
replace broad staff RLS in the first release
change existing order status transitions
change supplier evidence/OCR flow
change DVA/card matching logic
change shipper package/batch logic
change accounting/VAT/Sage posting gates
force all existing users through new routing before backfill is proven
```

New access logic must be additive first.

Existing supervisors must default to all-mode so current internal pages continue to behave as before until branch scoping is explicitly switched on.

---

## 17. Production Acceptance Tests

The MVP is not complete until these pass:

```text
Admin can create Ghana branch for Shipper A.
Admin can create Ghana branch for Shipper B.
Both branches can exist in Ghana.
Admin can create Nigeria branch for Shipper A separately.
Ghana branch uses Ghana country/currency.
Nigeria branch uses Nigeria country/currency.
Admin cannot create a branch with more than one country in MVP.
Admin cannot create a hub whose country conflicts with branch country.
Admin cannot create customer/importer under a branch with mismatched country.
Order form only shows hubs for assigned shipping-company branch.
Order form does not show same-country hubs from another branch.
Order creation rejects wrong-branch hub.
Order creation defensively rejects branch/country mismatch.
Order creation blocks if no FX rate exists for branch country.
Admin can create shipper user.
Admin can create customer/importer user.
New user must change temporary password.
Admin can disable and reactivate user.
Existing admin can still log in after access-table migration.
Existing supervisor can still log in after access-table migration.
Existing shipper user can still log in after access-table migration.
Existing importer/operator can still log in after access-table migration.
Legacy fallback routing works when platform profile is missing during transition.
Supervisor all-mode sees all branches.
Supervisor assigned-mode sees only assigned branch.
Supervisor assigned-mode with no branch sees nothing.
Supervisor can reset assigned-branch user.
Supervisor cannot reset admin.
Supervisor cannot reset another supervisor.
Supervisor cannot reset user outside visible branch.
Shipper user sees only own branch.
Customer/importer user sees only own branch.
Existing order lifecycle still works.
Existing DVA/card matching still works.
Existing shipper flow still works.
Existing accounting/VAT controls still work.
Existing final document/accounting handoff still works.
```

---

## Final Locked MVP

A production-level but minimal multi-tenant MVP where admin can onboard multiple country-specific shipping-company branches, including multiple shipping companies in the same country; each branch has one country/currency lane; customers/importers are assigned to a shipping-company branch; users are manually created with temporary passwords; orders use the assigned branch and its country FX; supervisors can be all-branch or assigned-branch; existing logins are protected through additive backfill and fallback routing; and no existing order, payment, shipping, accounting, VAT, or document flow is broken.

Anything beyond this is phase 2.
