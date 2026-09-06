# Sign-in: Active Directory, LDAP and SSO

How to connect TaskSense to your identity provider.

Whatever you configure, **keep at least one local administrator account**. An
identity-provider outage should not lock you out of your own installation.

---

## Active Directory / LDAP

The common case for an on-premise installation, and the one to start with if you
run AD.

**LDAP is configured inside the application, not in `.env`.** There are no
`LDAP_*` environment variables: a workspace administrator opens
**Admin → Authentication** and manages the directories there — several
independent domains if the organisation has them (head office and each
subsidiary's own forest), tried in order at every sign-in. Bind passwords are
stored AES-256-GCM encrypted (keyed off `STORAGE_SECRET`), the CA certificate
is pasted as PEM text (no file on the server, no mount), every directory has a
live **Test connection** that runs the same code sign-in does, and a save
applies within about 30 seconds — no restart, no container access.

> Upgrading from a version that used `LDAP_*` in `.env`: those lines are now
> ignored. Re-enter the directory in Admin → Authentication (the connection
> test will confirm it) and delete them from `.env`.

### Getting to the screen on a fresh install

1. Set `FIRST_ADMIN_EMAIL` in `.env` (the wizard asks for it). First boot
   creates that account **without a password**.
2. Open TaskSense, choose **Create account** with that email and set a
   password — this claims the bootstrap admin. (The register form stays
   visible until the claim happens, even though self-registration is closed
   by default on-premise.)
3. Go to **Admin → Authentication**, add your directories, run each one's
   **Test connection**, save.

### What TaskSense does at sign-in

1. Binds as a read-only service account.
2. Searches for the user with the filter you supply.
3. Binds **as that user** with the password they typed — this is the only thing
   that checks it. No password is stored locally, so a compromised TaskSense
   database yields no directory credentials.
4. Reads their group membership and maps it to a role.
5. First sign-in creates the account on the spot, in the installation's single
   workspace. There is ONE login form: people type an email **or** a directory
   username — the directories are tried first, the local account is the
   fallback.

### What you need from your directory team

| | Example |
| --- | --- |
| An `ldaps://` URL | `ldaps://dc01.bank.internal:636` |
| A read-only service account | `CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal` |
| The subtree to search | `DC=bank,DC=internal` |
| Your issuing CA, as PEM text | contents of `bank-ca.pem` |
| Two groups, for admins and users | `CN=TaskSense-Admins,OU=Groups,DC=bank,DC=internal` |

All of it goes into the Admin → Authentication form. Use `ldaps://` — the
application refuses plain `ldap://` on-premise unless the directory's
lab-only "allow an insecure connection" switch is set.

### Choosing the user filter

`{{username}}` is replaced with what the user typed, escaped so it cannot alter
the query.

| Directory | Filter | Users sign in with |
| --- | --- | --- |
| Active Directory | `(sAMAccountName={{username}})` | `arustamli` |
| Active Directory, by email | `(userPrincipalName={{username}})` | `arustamli@bank.internal` |
| Either, accepting both | `(\|(sAMAccountName={{username}})(userPrincipalName={{username}}))` | either |
| OpenLDAP / 389DS | `(uid={{username}})` | `arustamli` |

Restrict it if you do not want every directory account to have access:

```
(&(sAMAccountName={{username}})(memberOf=CN=TaskSense-Users,OU=Groups,DC=bank,DC=internal))
```

### Group to role mapping

Semicolon-separated `<group DN>=<role>` in the directory's "group to role
mapping" field. Roles: `admin`, `lead`, `member`, `viewer`, or any custom role
you have defined.

Re-read at **every** sign-in. Removing someone from a group in AD drops their
access at their next login, with no action in TaskSense. The corollary: role
changes made inside TaskSense to a directory-managed account do not persist —
manage those accounts through your directory.

Someone in several mapped groups gets the most privileged of them. Someone in
none signs in with the default member role; add `(memberOf=…)` to the filter if
they should not sign in at all.

### Testing it

Use the directory's own **Test connection** button: it signs in as the service
account, and — given a real username, optionally with that user's password —
also checks the filter, the attributes, and the resolved role, end to end.
Nothing is saved by a test. To cross-check from the host first:

```bash
ldapsearch -H ldaps://dc01.bank.internal:636 \
  -D "CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal" -W \
  -b "DC=bank,DC=internal" "(sAMAccountName=arustamli)" mail displayName memberOf
```

If that returns the user, TaskSense will find them too. Sign-in activity lands
in the application log:

```bash
docker compose -f compose/docker-compose.yml logs app | grep -i ldap
```

### When it does not work

| Symptom | Cause |
| --- | --- |
| "The directory is not reachable" | Service account credentials, or the host/port. The Test connection result names the actual reason. |
| "clear text" refusal | The server URL uses `ldap://`. Use `ldaps://` (or, for an isolated lab only, the insecure switch). |
| Certificate errors | The pasted CA is missing or the wrong one. Paste the issuing CA's PEM into the directory's CA field. |
| "Invalid username or password" for a user you know exists | The filter does not match them. Run Test connection with their username. |
| Everyone signs in as a plain member | The group → role mapping's DNs do not match. Copy them exactly from `ldapsearch` output — the whole DN, not the `CN`. |
| "Your directory account has no email address" | The entry has no `mail` attribute. Email is how TaskSense joins the directory identity to a local record. Change the email attribute field if yours uses another. |
| Directory sign-in silently stopped after `STORAGE_SECRET` changed | Stored bind passwords can no longer be decrypted. Re-enter them in Admin → Authentication. |

---

## OIDC — Keycloak, AD FS, Azure AD, Okta

One configuration covers all of them; only the issuer URL differs.

```bash
OIDC_ISSUER=https://sso.bank.internal/realms/corporate
OIDC_CLIENT_ID=tasksense
OIDC_CLIENT_SECRET=<from your IdP>
OIDC_REDIRECT_URI=https://tasksense.bank.internal/api/v1/auth/oidc/callback
OIDC_LABEL=Sign in with corporate account
```

Register `OIDC_REDIRECT_URI` at the provider **exactly** as written, including
scheme and trailing path. A mismatch is the single most common failure and the
error message comes from the IdP, not from us.

Issuer URLs:

| Provider | Issuer |
| --- | --- |
| Keycloak | `https://<host>/realms/<realm>` |
| AD FS | `https://<host>/adfs` |
| Azure AD | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Okta | `https://<org>.okta.com` |

Scopes: `openid`, `profile`, `email`. The email claim is required — it is how
the identity is joined to a TaskSense account.

> Azure AD is a cloud service. An installation with no route to the internet
> cannot use it; use AD FS or LDAP against your on-premise directory instead.

---

## Local passwords

Available unless an administrator turns the method off in
Admin → Authentication (directory-only installations). **Self-registration is
closed by default on-premise**: accounts come from the directory, from an
admin invite, or from the one bootstrap exception — `FIRST_ADMIN_EMAIL`, whose
unclaimed account keeps the register form reachable until its password is set.
An admin can reopen self-registration on the same screen. Password
requirements are set in Admin → Access control (minimum length, 6–32
characters); the policy applies to new accounts as well as to password
changes.

There is no self-service password reset — no assumption is made that the
installation can send email. An administrator sets a password in
Admin → Members, which ends every session on that account.

---

## Personal access tokens

For scripts and integrations rather than people. Created by each user in their
profile, scoped read or write, with an optional expiry. Only a SHA-256 hash is
stored; the token is shown once.

```bash
curl -H "Authorization: Bearer tsk_..." https://tasksense.bank.internal/api/v1/tasks
```

---

## Not supported

- **SAML 2.0** — if your IdP only speaks SAML, raise it before signing. OIDC
  covers Keycloak, AD FS 2016+, Azure AD and Okta.
- **SCIM provisioning** — accounts are created on first sign-in and their role
  follows directory group membership. There is no push from your IdP, so a
  disabled directory account cannot sign in, but an existing session survives
  until it expires. Set `SESSION_TTL_HOURS` accordingly.
- **Multi-factor authentication inside TaskSense** — get it from your identity
  provider by using OIDC or LDAP for sign-in.
