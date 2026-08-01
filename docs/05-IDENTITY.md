# Sign-in: Active Directory, LDAP and SSO

How to connect TaskSense to your identity provider.

Whatever you configure, **keep at least one local administrator account**. An
identity-provider outage should not lock you out of your own installation.

---

## Active Directory / LDAP

The common case for an on-premise installation, and the one to start with if you
run AD.

### What TaskSense does

1. Binds as a read-only service account.
2. Searches for the user with the filter you supply.
3. Binds **as that user** with the password they typed — this is the only thing
   that checks it. No password is stored locally, so a compromised TaskSense
   database yields no directory credentials.
4. Reads their group membership and maps it to a role.

### What you need from your directory team

| | Example |
| --- | --- |
| An `ldaps://` URL | `ldaps://dc01.bank.internal:636` |
| A read-only service account | `CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal` |
| The subtree to search | `DC=bank,DC=internal` |
| Your issuing CA, as PEM | `bank-ca.pem` |
| Two groups, for admins and users | `CN=TaskSense-Admins,OU=Groups,DC=bank,DC=internal` |

### Configuration

```bash
LDAP_URL=ldaps://dc01.bank.internal:636
LDAP_BIND_DN=CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal
LDAP_BIND_PASSWORD=<service account password>
LDAP_BASE_DN=DC=bank,DC=internal
LDAP_USER_FILTER=(sAMAccountName={{username}})
LDAP_TLS_CA=/certs/bank-ca.pem
LDAP_GROUP_MAP=CN=TaskSense-Admins,OU=Groups,DC=bank,DC=internal=admin;CN=TaskSense-Users,OU=Groups,DC=bank,DC=internal=member
LDAP_LABEL=Sign in with your bank account
```

Put the CA where the container can see it. `compose/certs/` is mounted at
`/certs`, read-only:

```bash
cp /etc/ssl/certs/bank-ca.pem compose/certs/
```

`LDAP_TLS_CA` is the path **inside** the container — `/certs/bank-ca.pem` —
not the path on the host. Getting that wrong fails at first sign-in rather than
at startup, which is why `./tasksense` binds to the directory and tells you
before installing.

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

```bash
LDAP_USER_FILTER=(&(sAMAccountName={{username}})(memberOf=CN=TaskSense-Users,OU=Groups,DC=bank,DC=internal))
```

### Group to role mapping

Semicolon-separated `<group DN>=<role>`. Roles: `admin`, `lead`, `member`,
`viewer`, or any custom role you have defined.

Re-read at **every** sign-in. Removing someone from a group in AD drops their
access at their next login, with no action in TaskSense. The corollary: role
changes made inside TaskSense to a directory-managed account do not persist —
manage those accounts through your directory.

Someone in several mapped groups gets the most privileged of them. Someone in
none signs in with the default member role; add `(memberOf=…)` to the filter if
they should not sign in at all.

### Testing it

```bash
# From the host, before involving TaskSense:
ldapsearch -H ldaps://dc01.bank.internal:636 \
  -D "CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal" -W \
  -b "DC=bank,DC=internal" "(sAMAccountName=arustamli)" mail displayName memberOf
```

If that returns the user, TaskSense will find them too. Then sign in through the
web interface and check the result:

```bash
docker compose -f compose/docker-compose.yml logs app | grep -i ldap
```

### When it does not work

| Symptom | Cause |
| --- | --- |
| "The directory is not reachable" | Service account credentials, or the host/port. The exact reason is in the log. |
| "clear text" error at startup | `LDAP_URL` uses `ldap://`. On-premise requires `ldaps://`. |
| Certificate errors | `LDAP_TLS_CA` is missing, wrong, or not mounted into the container. |
| "Invalid username or password" for a user you know exists | The filter does not match them. Test it with `ldapsearch` first. |
| Everyone signs in as a plain member | `LDAP_GROUP_MAP` group DNs do not match. Copy them exactly from `ldapsearch` output — the whole DN, not the `CN`. |
| "Your directory account has no email address" | The entry has no `mail` attribute. Email is how TaskSense joins the directory identity to a local record. Set `LDAP_ATTR_EMAIL` if yours uses another attribute. |

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

Always available. Requirements are set in Admin → Access control (minimum
length, 6–32 characters). The policy applies to new accounts as well as to
password changes.

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
