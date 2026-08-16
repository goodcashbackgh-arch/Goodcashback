# PATCH_C2_LOCAL_LIVE_AUTH_RUNBOOK_V1

Purpose: close Patch C without enabling Vercel preview deployments. Run the Patch C branch locally while it talks to the existing live Supabase project.

## 0. Database prerequisite

Run this migration once in Supabase SQL Editor if it has not already been run:

`supabase/migrations/20260816_complete_required_password_change_v1.sql`

Do not rerun the earlier Patch C onboarding migration; its postflight already passed.

## 1. Get the Patch C branch locally

From the existing repository checkout:

```bash
git fetch origin
git switch agent/onboarding-access-completion-v1
git pull --ff-only origin agent/onboarding-access-completion-v1
npm install
```

## 2. Local environment

Create or update `.env.local` with the same live Supabase project used by the production app:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=<live Supabase project URL>
NEXT_PUBLIC_SUPABASE_ANON_KEY=<live anon key>
SUPABASE_SERVICE_ROLE_KEY=<live service-role key>
```

`SUPABASE_SECRET_KEY` may be used instead of `SUPABASE_SERVICE_ROLE_KEY` if that is the server secret already used for the project.

Never commit `.env.local` or paste the service-role/secret key into chat, GitHub, SQL, screenshots, or client-side code.

## 3. Start only the local app

```bash
npm run dev
```

Open:

`http://localhost:3000/login`

This does not alter the Vercel preview policy and does not create a Vercel deployment.

## 4. Create the disposable user

Log in locally using an existing internal/admin account and open the onboarding workspace.

Create exactly this disposable user so the verifier needs no edits:

- Email: `patch-c-test-20260816-2205@example.com`
- Full name: `Patch C Test User`
- Relationship: use the normal test branch relationship
- Portal roles: `Customer + Importer`
- Importer: use an existing safe test importer/branch only

Expected result: the admin screen shows the email and generated temporary password once. Copy the temporary password.

If user creation fails, stop. Do not create another email until the failure is reviewed; Patch C compensation is intended to prevent a half-created usable login.

## 5. Prove first-login password change

Open a private/incognito browser window and go to:

`http://localhost:3000/login`

Sign in with:

- `patch-c-test-20260816-2205@example.com`
- the temporary password shown in step 4

Expected:

1. temporary credentials authenticate;
2. `/auth/check` sends the user to `/auth/change-password` before any portal destination;
3. set a new test password on that screen;
4. the password update succeeds;
5. the app returns through `/auth/check` using the same authenticated identity;
6. legacy portal routing after the password change is allowed to remain as-is until Patch F.

## 6. SQL verifier

Run:

`docs/testing/20260816_patch_c2_disposable_user_verifier_v1.sql`

It is read-only and already targets the email above.

Required result:

```text
probe = PATCH_C2_DISPOSABLE_USER_VERIFIER_V1
ready = true
review_required = 0
```

The detailed checks must show:

- exactly one Auth user;
- exactly one platform profile;
- exactly one operator;
- active operator/importer link;
- active customer/importer membership(s);
- profile and operator active;
- `must_change_password = false`;
- same Auth ID in Auth/profile/operator;
- onboarding audit present;
- required-password-change audit present;
- Auth login observed.

Paste only the verifier JSON result back into ChatGPT. Do not paste passwords or secret keys.

## 7. C2 pass rule

Patch C2 passes only when both are true:

- observed browser behaviour: temporary login worked and forced password change completed;
- SQL verifier returns `ready=true` and `review_required=0`.

Only then may Patch C be marked closed.
