#!/usr/bin/env bash
#
# The configuration step: every setting, asked in order, with what it does.
#
#   scripts/wizard/configure.sh           ask everything, write compose/.env
#   scripts/wizard/configure.sh --edit    change one section of an existing .env
#
# This is docs/17-ENVIRONMENT.md turned inside out. The reference answers
# "what does STORAGE_SECRET do?" for somebody who already knows to ask; this
# answers it for somebody who does not, at the moment it matters.
#
# ── How the file is written ──────────────────────────────────────────────────
#
# .env is rendered FROM .env.example: every line of the example is copied, and
# only the values are replaced. So the result keeps all of its comments, its
# section headers and its commented-out optional settings, and is byte-for-byte
# the file the documentation describes — apart from the answers.
#
# That is deliberate, and it is the whole reason this is safe to ship. A wizard
# that wrote its own minimal .env would create a second configuration format
# that nobody documents, and the first support call about a setting we did not
# think to emit would have no good answer. Rendering the example instead makes
# key-set equivalence true by construction rather than by test — though it is
# tested too.
#
# Policy the wizard enforces rather than asks: AGENT_EXECUTOR is always off (no
# execution sandbox ships on-premise), and the import worker always comes with
# WORKER_ROLE=api.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

declare -A ANSWER=()
declare -A EXAMPLE_DEFAULT=()

# ── the answer set ───────────────────────────────────────────────────────────

cfg_set() { ANSWER["$1"]="$2"; }
cfg_get() { printf '%s' "${ANSWER[$1]-}"; }
cfg_has() { [ -n "${ANSWER[$1]+set}" ]; }

# Whatever the example suggests becomes the offered default, so the two files
# cannot drift: change .env.example and the wizard follows. A <CHANGE_ME_…>
# placeholder is not a suggestion — offering it as the default would invite
# somebody to press Enter on it.
load_example_defaults() {
  local line key value
  while IFS= read -r line; do
    case "${line}" in
      \#*=*) line="${line#\#}" ;;   # a commented-out optional still has a default
      *=*)   ;;
      *)     continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    # Section rules and prose are not settings.
    case "${key}" in
      *[!A-Z0-9_]*|"") continue ;;
    esac
    case "${value}" in *"<CHANGE_ME"*) value="" ;; esac
    EXAMPLE_DEFAULT["${key}"]="${value}"
  done < "${EXAMPLE_FILE}"
}

example_default() { printf '%s' "${EXAMPLE_DEFAULT[$1]-}"; }

# The current answer if there is one (--edit, a resumed draft), else the example's.
default_for() {
  local v; v="$(cfg_get "$1")"
  case "${v}" in *"<CHANGE_ME"*) v="" ;; esac
  printf '%s' "${v:-$(example_default "$1")}"
}

# Seed from an existing .env, so --edit changes one thing and keeps the rest.
load_current() {
  local from="${1:-${ENV_FILE}}"
  [ -f "${from}" ] || return 0
  local line key
  while IFS= read -r line; do
    case "${line}" in
      \#*|"") continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    case "${key}" in *[!A-Z0-9_]*|"") continue ;; esac
    cfg_set "${key}" "${line#*=}"
  done < "${from}"
}

# COMPOSE_PROFILES is two independent answers — which database, and whether a
# separate import worker runs — kept in one value, in a fixed order.
profile_set() {  # profile_set bundled-mongo|import-worker on|off
  local name="$1" want="$2" p bm=0 iw=0 others="" out=""
  for p in $(cfg_get COMPOSE_PROFILES | tr ',' ' '); do
    case "${p}" in
      bundled-mongo) bm=1 ;;
      import-worker) iw=1 ;;
      *) others="${others:+${others},}${p}" ;;
    esac
  done
  case "${name}" in
    bundled-mongo) if [ "${want}" = "on" ]; then bm=1; else bm=0; fi ;;
    import-worker) if [ "${want}" = "on" ]; then iw=1; else iw=0; fi ;;
  esac
  [ "${bm}" = "1" ] && out="bundled-mongo"
  [ "${iw}" = "1" ] && out="${out:+${out},}import-worker"
  [ -n "${others}" ] && out="${out:+${out},}${others}"
  cfg_set COMPOSE_PROFILES "${out}"
}
profile_on() { case ",$(cfg_get COMPOSE_PROFILES | tr -d ' ')," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ── rendering ────────────────────────────────────────────────────────────────

# Walk the example; replace values we have answers for, uncommenting the line if
# it was an optional. Everything else is copied through untouched.
render_env() {
  local out="$1" line key rendered
  local -A emitted=()

  : > "${out}"
  chmod 600 "${out}"   # before anything is written to it, not after

  while IFS= read -r line; do
    rendered="${line}"
    case "${line}" in
      \#*=*|*=*)
        key="${line#\#}"; key="${key%%=*}"
        case "${key}" in
          *[!A-Z0-9_]*|"") ;;
          *)
            # A key the example lists twice (it does not) is written once.
            if cfg_has "${key}" && [ -z "${emitted[$key]+set}" ]; then
              if [ -n "$(cfg_get "${key}")" ]; then
                rendered="${key}=$(cfg_get "${key}")"
              elif [ "${line#\#}" = "${line}" ]; then
                # An empty answer for a setting the example has ACTIVE — a
                # placeholder like MONGO_PASSWORD with your own MongoDB, or
                # COMPOSE_PROFILES with nothing in it — is written empty.
                # Copying the example line would keep the placeholder.
                rendered="${key}="
              else
                # An empty answer for an optional means "leave it unset". Keep
                # the example's commented line so it is still documented.
                rendered="${line}"
              fi
              emitted["${key}"]=1
            fi
            ;;
        esac
        ;;
    esac
    printf '%s\n' "${rendered}" >> "${out}"
  done < "${EXAMPLE_FILE}"

  # Anything the operator added by hand that the example does not know about.
  # Dropping it silently on a reconfigure would be the worst kind of bug: the
  # setting disappears, and the symptom shows up somewhere else entirely.
  local -a extra=()
  for key in "${!ANSWER[@]}"; do
    [ -n "${emitted[$key]+set}" ] && continue
    [ -n "$(cfg_get "${key}")" ] || continue
    extra+=("${key}")
  done
  if [ "${#extra[@]}" -gt 0 ]; then
    {
      printf '\n\n'
      printf '# ─────────────────────────────────────────────────────────────────────────────\n'
      printf '# Settings added on this host\n'
      printf '#\n'
      printf '# Not part of .env.example. Kept as they were found.\n'
      printf '# ─────────────────────────────────────────────────────────────────────────────\n\n'
    } >> "${out}"
    while IFS= read -r key; do
      printf '%s=%s\n' "${key}" "$(cfg_get "${key}")" >> "${out}"
    done < <(printf '%s\n' "${extra[@]}" | sort)
  fi
}

# ── validators specific to these questions ───────────────────────────────────

valid_hours() {
  case "$1" in
    ''|*[!0-9]*) printf 'a whole number of hours'; return 1 ;;
  esac
  [ "$1" -eq 0 ] && warn "0 means sessions never expire — a stolen session stays valid for good"
  return 0
}

valid_number() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && return 0
  printf 'a number, e.g. 20'
  return 1
}

valid_pem() {
  [ -f "$1" ] || { printf 'no such file on this host: %s' "$1"; return 1; }
  grep -q 'BEGIN CERTIFICATE' "$1" || { printf 'not a PEM certificate (no BEGIN CERTIFICATE line)'; return 1; }
  return 0
}

valid_mongo_uri() {
  case "$1" in
    mongodb://*|mongodb+srv://*) return 0 ;;
    *) printf 'must start with mongodb:// or mongodb+srv://'; return 1 ;;
  esac
}

# ── section 1: version and access ────────────────────────────────────────────

section_version() {
  ui_step 1 9 "Version and access"
  ui_text "Which release to run, and where it listens on this host."

  ui_ask "TASKSENSE_VERSION" "$(default_for TASKSENSE_VERSION)" \
    "Pin it explicitly. Never \"latest\": a restart would then silently move you to a different version, which turns an unrelated reboot into an unplanned upgrade."
  cfg_set TASKSENSE_VERSION "${UI_VALUE}"

  printf '\n'
  ui_text "TaskSense listens on this host, and a reverse proxy in front of it terminates TLS."
  ui_ask "BIND_ADDRESS" "$(default_for BIND_ADDRESS)" \
    "127.0.0.1 means only this machine can connect — correct when the proxy runs here. Use 0.0.0.0 only if the proxy is on another host, and then firewall the port."
  cfg_set BIND_ADDRESS "${UI_VALUE}"

  ui_ask "HTTP_PORT" "$(default_for HTTP_PORT)" \
    "The port on this host. Change it if something else already uses 3000." ui_valid_port
  cfg_set HTTP_PORT "${UI_VALUE}"
}

# ── section 2: identity and trust ────────────────────────────────────────────

section_identity() {
  ui_step 2 9 "This installation's identity"

  ui_ask "APP_URL" "$(default_for APP_URL)" \
    "The address users type, including https:// — e.g. https://tasksense.bank.internal. Sign-in redirects are built from it, so a wrong value breaks SSO in a way that is hard to trace: the login page appears, and the return trip lands nowhere." ui_valid_url
  cfg_set APP_URL "${UI_VALUE%/}"

  # Same host for UI and API is the normal case, and typing it twice is how the
  # two drift apart.
  cfg_set CORS_ALLOWED_ORIGINS "$(cfg_get APP_URL)"
  ok "CORS_ALLOWED_ORIGINS set to the same address"
  ui_hint "Change it by hand only if the UI is served from a different origin than the API."

  printf '\n'
  ui_ask "FIRST_ADMIN_EMAIL" "$(default_for FIRST_ADMIN_EMAIL)" \
    "Becomes the administrator of the new, empty workspace. No password is set for it — sign in through your identity provider, or claim the account with \"Create account\" on the login screen. There is no default credential to change afterwards." ui_valid_email
  cfg_set FIRST_ADMIN_EMAIL "${UI_VALUE}"

  printf '\n'
  ui_text "If anything TaskSense connects to — your own MongoDB, the mail relay, the identity provider, an internal model gateway — presents a certificate your organisation issued, the application needs your CA to trust it."
  local had=n current
  current="$(cfg_get NODE_EXTRA_CA_CERTS)"
  [ -n "${current}" ] && had=y
  if ui_yesno "Does your organisation use its own certificate authority?" "${had}"; then
    local suggested=""
    [ -n "${current}" ] && suggested="${COMPOSE_DIR}/certs/${current#/certs/}"
    ui_ask "CA bundle (PEM file on this host)" "${suggested}" \
      "Your root and any intermediate certificates in one PEM file, e.g. /etc/pki/ca-trust/source/anchors/bank-ca.pem. It is copied into compose/certs/, which the containers see as /certs — public certificates only, never a private key." valid_pem
    local src="${UI_VALUE}" name
    name="$(basename "${src}")"
    if [ "$(cd "$(dirname "${src}")" && pwd)/${name}" != "${COMPOSE_DIR}/certs/${name}" ]; then
      cp "${src}" "${COMPOSE_DIR}/certs/${name}"
      chmod 644 "${COMPOSE_DIR}/certs/${name}"
      ok "copied to compose/certs/${name}"
    fi
    cfg_set NODE_EXTRA_CA_CERTS "/certs/${name}"
    ok "NODE_EXTRA_CA_CERTS=/certs/${name} — every outbound TLS connection trusts it"
  else
    cfg_set NODE_EXTRA_CA_CERTS ""
    note "public certificate authorities only"
  fi
}

# ── section 3: secrets and database ──────────────────────────────────────────

section_secrets() {
  ui_step 3 9 "Secrets and database"
  ui_text "Values that must be generated rather than chosen go into your password manager, and belong with the database backup."

  ui_secret "STORAGE_SECRET" \
    "Encrypts stored credentials at rest — object-storage keys, model API keys, LDAP bind passwords. Changing it later makes those unreadable and they have to be re-entered by hand. A restore without this value restores unusable credentials, so back it up WITH the database, not instead of it." 32
  cfg_set STORAGE_SECRET "${UI_VALUE}"

  printf '\n'
  ui_text "TaskSense stores everything in MongoDB. The installation can bring its own, or use one you already run."
  ui_menu "Which database?" \
    "Bring one with it|a MongoDB container beside the application — most installations" \
    "Use my own|an existing replica set, or a server your DBAs run"

  if [ "${UI_CHOICE}" = "2" ]; then
    profile_set bundled-mongo off
    printf '\n'
    ui_text "Then TaskSense starts no database of its own. Give it the connection string; the account needs readWrite and dbAdmin on one database, and TaskSense creates its own collections and indexes there. For backups through ./scripts/backup.sh it also needs the backup and restore roles — docs/16-EXTERNAL-DATABASES.md."
    local ca_hint="tls=true&tlsCAFile=/certs/<your CA>.pem"
    [ -n "$(cfg_get NODE_EXTRA_CA_CERTS)" ] && ca_hint="tls=true&tlsCAFile=$(cfg_get NODE_EXTRA_CA_CERTS)"
    ui_ask "MONGODB_URI" "$(cfg_get MONGODB_URI)" \
      "e.g. mongodb://tasksense:PASSWORD@mongo-0.bank.internal:27017,mongo-1.bank.internal:27017,mongo-2.bank.internal:27017/?replicaSet=rs0&${ca_hint}&authSource=admin — percent-encode anything in the password that a URI reads as structure: / : @ ? # [ ] %." valid_mongo_uri
    cfg_set MONGODB_URI "${UI_VALUE}"

    ui_ask "MONGODB_DB" "$(default_for MONGODB_DB)" \
      "The database inside that server. Backups dump exactly this one."
    cfg_set MONGODB_DB "${UI_VALUE}"

    # Across a network: compression pays for itself, and server selection
    # deserves longer than the same-host default.
    cfg_set MONGODB_COMPRESSORS zlib
    cfg_set MONGODB_TIMEOUT_MS 15000
    ok "MONGODB_COMPRESSORS=zlib, MONGODB_TIMEOUT_MS=15000 — tuned for a database across the network"

    # Not used with an external database, and leaving the example's values would
    # suggest an account somebody should create.
    cfg_set MONGO_USER ""
    cfg_set MONGO_PASSWORD ""
    ui_hint "The bundled database will not be started. COMPOSE_PROFILES leaves bundled-mongo out."
  else
    profile_set bundled-mongo on
    cfg_set MONGODB_URI ""
    cfg_set MONGODB_COMPRESSORS none
    cfg_set MONGODB_TIMEOUT_MS ""
    ui_ask "MONGO_USER" "$(default_for MONGO_USER)" \
      "The database account the application uses. It is created on first start."
    cfg_set MONGO_USER "${UI_VALUE}"

    ui_secret "MONGO_PASSWORD" \
      "The password for that account. Generated is better than chosen — nothing types it by hand, so there is no reason for it to be memorable. It ends up inside a connection string, so it is drawn from hex: a / or + or = would end the password early and the database would be unreachable before the first query." 24 uri
    cfg_set MONGO_PASSWORD "${UI_VALUE}"
  fi

  printf '\n'
  ui_text "A licence lifts two limits: the 10-account cap and the 500-a-month automation allowance. Everything else in TaskSense is the same either way — there is no feature behind it."
  if ui_yesno "Do you have a licence key?" "$([ -n "$(cfg_get LICENSE_KEY)" ] && echo y || echo n)"; then
    ui_ask "LICENSE_KEY" "$(cfg_get LICENSE_KEY)" \
      "Starts with tsl_. Verified offline — no activation server, no phone-home, no usage reporting. Copy the whole line, including the tsl_ prefix: a key cut short fails as \"signature does not verify\"."
    cfg_set LICENSE_KEY "${UI_VALUE}"
  else
    cfg_set LICENSE_KEY ""
    note "running on free-tier limits — 10 accounts, 500 automation runs a month"
    ui_hint "Ask for one at ${SUPPORT_EMAIL}, with the organisation it is for and how many people will have accounts. It is one line added to .env, then a restart — docs/14-LICENSING.md."
  fi
}

# ── section 4: sign-in ───────────────────────────────────────────────────────

section_signin() {
  ui_step 4 9 "Sign-in"

  ui_ask "SESSION_TTL_HOURS" "$(default_for SESSION_TTL_HOURS)" \
    "How long a sign-in lasts, in hours. 12 covers a working day and is what we recommend for a bank; the application's own default is 720 (30 days). A workspace policy set in Admin → Security still wins." valid_hours
  cfg_set SESSION_TTL_HOURS "${UI_VALUE}"

  printf '\n'
  ui_text "Pick one primary method. Local passwords stay available whichever you choose, and you should keep at least one local administrator — otherwise an identity-provider outage locks you out of your own instance."

  ui_menu "How will people sign in?" \
    "Active Directory / LDAP|configured IN THE APP after install — nothing to type here" \
    "OIDC|Keycloak, AD FS, Azure AD, Okta" \
    "Local passwords only|no directory — accounts live in TaskSense" \
    "Decide later|configure it after the install"

  case "${UI_CHOICE}" in
    1) signin_ldap ;;
    2) signin_oidc ;;
    3) ok "local passwords only — people register with their email address" ;;
    4) note "skipped — docs/05-IDENTITY.md when you are ready" ;;
  esac
}

# There are no LDAP_* environment variables any more — directory sign-in is
# configured by the workspace administrator inside the application, where every
# directory (several independent domains, if the organisation has them) gets an
# encrypted bind password and its own live connection test, and changes apply
# without a restart. The wizard therefore has nothing to write and nothing to
# probe; its job is to say where the setting moved and how the first
# administrator gets in to reach it.
signin_ldap() {
  printf '\n'
  ok "nothing to configure here — LDAP moved into the application"
  ui_text "After the install: sign in as the administrator (FIRST_ADMIN_EMAIL — claim the account with \"Create account\" on the login screen, which sets its password), then open Admin → Authentication. Add your directories there — server URL, service account, base DN, user filter, group-to-role mapping, and the CA certificate pasted as text (no file mounts). Every directory has a live \"Test connection\" that runs the same code sign-in does."
  ui_hint "Self-registration is closed by default on-premise, so once LDAP is on, accounts only come from your directory or an invite — docs/05-IDENTITY.md."
}

signin_oidc() {
  printf '\n'
  ui_ask "OIDC_ISSUER" "$(default_for OIDC_ISSUER)" \
    "The issuer URL. Discovery must work from this host: the wizard fetches its .well-known/openid-configuration to check." ui_valid_url
  cfg_set OIDC_ISSUER "${UI_VALUE}"

  ui_ask "OIDC_CLIENT_ID" "$(default_for OIDC_CLIENT_ID)" "The client you registered at the provider."
  cfg_set OIDC_CLIENT_ID "${UI_VALUE}"

  ui_secret "OIDC_CLIENT_SECRET" "The client secret from the provider." 0
  cfg_set OIDC_CLIENT_SECRET "${UI_VALUE}"

  local redirect
  redirect="$(cfg_get APP_URL)/api/v1/auth/oidc/callback"
  cfg_set OIDC_REDIRECT_URI "${redirect}"
  ok "OIDC_REDIRECT_URI: ${redirect}"
  ui_hint "Register that exact URI at the provider — a mismatch is the single most common OIDC failure, and the error it produces names the provider, not us."

  printf '\n'
  ui_ask "OIDC_LABEL" "$(default_for OIDC_LABEL)" "The wording on the sign-in button."
  cfg_set OIDC_LABEL "${UI_VALUE}"
}

# ── section 5: mail ──────────────────────────────────────────────────────────

section_mail() {
  ui_step 5 9 "Mail"
  ui_text "Optional. Without it notifications still appear inside the application — only the emailed copy is skipped."

  if ! ui_yesno "Send email notifications?" y; then
    note "skipped — notifications stay in-app"
    return 0
  fi

  ui_ask "SMTP_HOST" "$(default_for SMTP_HOST)" "Your internal relay."
  cfg_set SMTP_HOST "${UI_VALUE}"

  ui_ask "SMTP_PORT" "$(default_for SMTP_PORT)" \
    "25 for an internal relay that does not authenticate, 587 for submission with STARTTLS, 465 for implicit TLS." ui_valid_port
  cfg_set SMTP_PORT "${UI_VALUE}"

  if [ "$(cfg_get SMTP_PORT)" = "465" ]; then
    cfg_set SMTP_SECURE true
  else
    cfg_set SMTP_SECURE false
  fi
  ok "SMTP_SECURE=$(cfg_get SMTP_SECURE)"
  ui_hint "true means TLS from the first byte (465). On 587 the connection starts plain and upgrades, which is still encrypted. A relay certificate from your own CA needs the CA from step 2."

  printf '\n'
  if ui_yesno "Does the relay require a username and password?" n; then
    ui_ask "SMTP_USER" "$(cfg_get SMTP_USER)" "The account TaskSense authenticates as."
    cfg_set SMTP_USER "${UI_VALUE}"
    ui_secret "SMTP_PASS" "Its password." 0
    cfg_set SMTP_PASS "${UI_VALUE}"
  fi

  printf '\n'
  ui_ask "EMAIL_FROM" "$(default_for EMAIL_FROM)" \
    "The From address. Many relays refuse mail from an address they do not own, so use one in your own domain."
  cfg_set EMAIL_FROM "${UI_VALUE}"
}

# ── section 6: uploads and Jira import ───────────────────────────────────────

section_storage() {
  ui_step 6 9 "Uploads and Jira import"
  ui_text "Attachments go to the data volume by default. That suits most installations — back it up together with the database. Shared or replicated storage is configured later from Admin → Storage, not here."

  ui_ask "STORAGE_MAX_FILE_MB" "$(default_for STORAGE_MAX_FILE_MB)" \
    "Per-file upload ceiling, in megabytes."
  cfg_set STORAGE_MAX_FILE_MB "${UI_VALUE}"
  ui_hint "Set the same limit on your reverse proxy (nginx: client_max_body_size ${UI_VALUE}m), or a large upload is rejected by the proxy before it reaches TaskSense."

  printf '\n'
  ui_text "Migrating from Jira? A Jira site backup (entities.xml — often tens of gigabytes) is uploaded, then imported in the background. For a migration, run that import in its own process, the import worker: a landing that exhausts its memory then cannot take the API down with it, and a worker that dies resumes from its last checkpoint."
  if ui_yesno "Will this installation import a Jira site backup?" "$(profile_on import-worker && echo y || echo n)"; then
    profile_set import-worker on
    cfg_set WORKER_ROLE api
    ok "import worker on — COMPOSE_PROFILES gets import-worker, the API runs with WORKER_ROLE=api"

    ui_ask "JIRA_BACKUP_MAX_GB" "$(default_for JIRA_BACKUP_MAX_GB)" \
      "The largest site backup accepted, in gigabytes. It is staged on the data volume, so keep at least twice this free there." valid_number
    cfg_set JIRA_BACKUP_MAX_GB "${UI_VALUE}"
    warn "set the reverse proxy's body limit for the import endpoints to match"
    ui_hint "examples/nginx.conf has the location blocks: a ${UI_VALUE} GB body and long timeouts on the upload paths only."
  else
    profile_set import-worker off
    cfg_set WORKER_ROLE all
    note "no separate worker — the API runs every workload itself (WORKER_ROLE=all)"
  fi
}

# ── section 7: AI ────────────────────────────────────────────────────────────

section_ai() {
  ui_step 7 9 "AI features"
  ui_text "Off unless you turn them on, and everything else works without them. When enabled they talk to an OpenAI-compatible endpoint running INSIDE your network — vLLM, Ollama, or a gateway — configured from Admin → Agents → Providers. Nothing is sent outside."

  # Not a question. Agent command execution needs a sandbox, and none ships
  # on-premise — "on" is refused at boot and "unsafe-host" would run
  # model-authored commands on this server.
  cfg_set AGENT_EXECUTOR off

  if ! ui_yesno "Enable the AI features?" "$([ "$(cfg_get AGENT_DISPATCHER)" = "on" ] && echo y || echo n)"; then
    cfg_set AGENT_DISPATCHER off
    ok "off — you can turn them on later without reinstalling"
    return 0
  fi

  cfg_set AGENT_DISPATCHER on
  ok "AGENT_DISPATCHER=on — the scheduler that advances agent tasks"
  note "AGENT_EXECUTOR stays off: running model-authored commands needs a sandbox, and none ships on-premise"
  note "connect your model endpoint after installing — docs/12-AI-MODELS.md"
}

# ── section 8: operations ────────────────────────────────────────────────────

section_operations() {
  ui_step 8 9 "Operations"

  ui_menu "Log format" \
    "json|one object per line, for Splunk, QRadar or Elastic" \
    "text|human-readable, for reading by eye during an install"
  if [ "${UI_CHOICE}" = "1" ]; then cfg_set LOG_FORMAT json; else cfg_set LOG_FORMAT text; fi

  printf '\n'
  ui_text "These are the application's own level names, not syslog's. There is no \"info\" — \"log\" is the ordinary one that means it."
  ui_menu "How much should it log?" \
    "log|the ordinary level — startup, sign-ins, errors" \
    "warn|quieter: only what needs attention" \
    "debug|while diagnosing something; noisy" \
    "verbose|everything, including per-request detail"
  case "${UI_CHOICE}" in
    1) cfg_set LOG_LEVEL log ;;
    2) cfg_set LOG_LEVEL warn ;;
    3) cfg_set LOG_LEVEL debug ;;
    4) cfg_set LOG_LEVEL verbose ;;
  esac

  printf '\n'
  if ui_yesno "Expose Prometheus metrics?" "$([ -n "$(cfg_get METRICS_TOKEN)" ] && echo y || echo n)"; then
    cfg_set METRICS_ENABLED true
    [ -n "$(cfg_get METRICS_TOKEN)" ] || cfg_set METRICS_TOKEN "$(ui_generate_secret uri 32)"
    ok "metrics at $(cfg_get APP_URL)/api/v1/metrics"
    ui_hint "The endpoint requires a bearer token, which has been generated. It is in .env as METRICS_TOKEN — put it in your Prometheus scrape config."
  else
    cfg_set METRICS_ENABLED ""
    cfg_set METRICS_TOKEN ""
  fi

  printf '\n'
  ui_text "The interactive API browser (Swagger, at /api/v1/swagger) publishes the complete API surface. The application serves it unless told not to; for a bank, leave it off and turn it on while somebody is building an integration."
  if ui_yesno "Serve the API browser?" "$([ "$(cfg_get SWAGGER_ENABLED)" = "true" ] && echo y || echo n)"; then
    cfg_set SWAGGER_ENABLED true
    warn "the API browser is on — SWAGGER_ENABLED=false in .env turns it off again"
  else
    cfg_set SWAGGER_ENABLED false
    ok "SWAGGER_ENABLED=false"
  fi

  printf '\n'
  ui_text "Some installations need TaskSense to reach other internal systems: a self-hosted GitLab, an internal Jira. Everything not listed is refused, including private and link-local addresses — which is what stops a webhook URL entered in the admin console from being used to probe your network."
  if ui_yesno "Allow outbound calls to specific internal hosts?" "$([ -n "$(cfg_get EGRESS_ALLOWLIST)" ] && echo y || echo n)"; then
    ui_ask "EGRESS_ALLOWLIST" "$(default_for EGRESS_ALLOWLIST)" \
      "Hostnames, comma-separated. No scheme, no path."
    cfg_set EGRESS_ALLOWLIST "${UI_VALUE}"
  else
    cfg_set EGRESS_ALLOWLIST ""
  fi
}

# ── section 9: resources ─────────────────────────────────────────────────────

section_resources() {
  ui_step 9 9 "Resource limits"
  ui_text "From docs/11-SIZING.md. \"Users\" means people with accounts — about a fifth of a team is active at once, and concurrency is what actually costs resources. The API is one process by design: it grows by getting more memory and cores, not more copies."

  ui_menu "How many people will have accounts?" \
    "Up to 50|host: 2 cores, 4 GB, 20 GB disk" \
    "Up to 200|host: 4 cores, 8 GB, 100 GB SSD" \
    "Up to 1000|host: 8 cores, 16 GB, 500 GB SSD" \
    "Keep the defaults|2 cores and 2 GB each"

  # Memory splits roughly in half between the application and MongoDB; each
  # heap is about 75% of its container, MongoDB's cache about half of its own.
  case "${UI_CHOICE}" in
    1) cfg_set APP_CPU_LIMIT 1; cfg_set APP_MEMORY_LIMIT 2g; cfg_set APP_HEAP_MB 1536
       cfg_set MONGO_CPU_LIMIT 1; cfg_set MONGO_MEMORY_LIMIT 2g; cfg_set MONGO_CACHE_GB 1 ;;
    2) cfg_set APP_CPU_LIMIT 2; cfg_set APP_MEMORY_LIMIT 4g; cfg_set APP_HEAP_MB 3072
       cfg_set MONGO_CPU_LIMIT 2; cfg_set MONGO_MEMORY_LIMIT 4g; cfg_set MONGO_CACHE_GB 2 ;;
    3) cfg_set APP_CPU_LIMIT 4; cfg_set APP_MEMORY_LIMIT 8g; cfg_set APP_HEAP_MB 6144
       cfg_set MONGO_CPU_LIMIT 4; cfg_set MONGO_MEMORY_LIMIT 8g; cfg_set MONGO_CACHE_GB 4
       note "at this size consider your own MongoDB replica set and shared object storage — docs/11-SIZING.md" ;;
    *) cfg_set APP_CPU_LIMIT "$(default_for APP_CPU_LIMIT)"; cfg_set APP_MEMORY_LIMIT "$(default_for APP_MEMORY_LIMIT)"
       cfg_set APP_HEAP_MB "$(default_for APP_HEAP_MB)"
       cfg_set MONGO_CPU_LIMIT "$(default_for MONGO_CPU_LIMIT)"; cfg_set MONGO_MEMORY_LIMIT "$(default_for MONGO_MEMORY_LIMIT)"
       cfg_set MONGO_CACHE_GB "$(default_for MONGO_CACHE_GB)" ;;
  esac
  ok "app: $(cfg_get APP_CPU_LIMIT) cores / $(cfg_get APP_MEMORY_LIMIT), heap $(cfg_get APP_HEAP_MB) MB"
  if profile_on bundled-mongo; then
    ok "mongo: $(cfg_get MONGO_CPU_LIMIT) cores / $(cfg_get MONGO_MEMORY_LIMIT), cache $(cfg_get MONGO_CACHE_GB) GB"
  fi
  if profile_on import-worker; then
    cfg_set WORKER_CPU_LIMIT "$(default_for WORKER_CPU_LIMIT)"
    cfg_set WORKER_MEMORY_LIMIT "$(default_for WORKER_MEMORY_LIMIT)"
    cfg_set WORKER_HEAP_MB "$(default_for WORKER_HEAP_MB)"
    ok "import worker: $(cfg_get WORKER_CPU_LIMIT) cores / $(cfg_get WORKER_MEMORY_LIMIT), heap $(cfg_get WORKER_HEAP_MB) MB — a large Jira landing needs it"
  fi
}

# ── review ───────────────────────────────────────────────────────────────────

configure_summary() {
  UI_SUMMARY=()
  ui_summary_add "Version" "$(cfg_get TASKSENSE_VERSION)"
  ui_summary_add "Address" "$(cfg_get APP_URL)"
  ui_summary_add "Listens on" "$(cfg_get BIND_ADDRESS):$(cfg_get HTTP_PORT)"
  ui_summary_add "Administrator" "$(cfg_get FIRST_ADMIN_EMAIL)"
  ui_summary_add "Your CA" "$([ -n "$(cfg_get NODE_EXTRA_CA_CERTS)" ] && cfg_get NODE_EXTRA_CA_CERTS || echo "none — public CAs only")"
  ui_summary_secret "Storage secret" "$(cfg_get STORAGE_SECRET)"
  if [ -n "$(cfg_get MONGODB_URI)" ]; then
    # The URI carries the password; the summary must not.
    ui_summary_add "Database" "your own — $(uri_redacted "$(cfg_get MONGODB_URI)"), db $(cfg_get MONGODB_DB)"
  else
    ui_summary_add "Database" "bundled container"
    ui_summary_add "Database user" "$(cfg_get MONGO_USER)"
    ui_summary_secret "Database password" "$(cfg_get MONGO_PASSWORD)"
  fi
  local profiles; profiles="$(cfg_get COMPOSE_PROFILES)"
  ui_summary_add "Profiles" "${profiles:-(none)}"
  ui_summary_add "Session lifetime" "$(cfg_get SESSION_TTL_HOURS) h"

  if [ -n "$(cfg_get OIDC_ISSUER)" ]; then
    ui_summary_add "Sign-in" "OIDC — $(cfg_get OIDC_ISSUER)"
  else
    ui_summary_add "Sign-in" "local passwords (LDAP, if wanted, is set up in the app)"
  fi

  if [ -n "$(cfg_get SMTP_HOST)" ]; then
    ui_summary_add "Mail" "$(cfg_get SMTP_HOST):$(cfg_get SMTP_PORT)"
  else
    ui_summary_add "Mail" "not configured — notifications stay in-app"
  fi

  ui_summary_add "Import worker" "$(profile_on import-worker && echo "on (WORKER_ROLE=api)" || echo "off")"
  ui_summary_add "AI features" "$([ "$(cfg_get AGENT_DISPATCHER)" = "on" ] && echo "on (command execution off)" || echo "off")"
  ui_summary_add "API browser" "$([ "$(cfg_get SWAGGER_ENABLED)" = "true" ] && echo "on" || echo "off")"
  ui_summary_add "Licence" "$([ -n "$(cfg_get LICENSE_KEY)" ] && echo "supplied" || echo "free tier")"
  ui_summary_add "Resources" "app $(cfg_get APP_CPU_LIMIT)/$(cfg_get APP_MEMORY_LIMIT) · mongo $(cfg_get MONGO_CPU_LIMIT)/$(cfg_get MONGO_MEMORY_LIMIT)"
  ui_summary_show "What will be written"
}

# ── entry ────────────────────────────────────────────────────────────────────

ALL_SECTIONS=(section_version section_identity section_secrets section_signin
              section_mail section_storage section_ai section_operations
              section_resources)

configure_all() {
  local section
  for section in "${ALL_SECTIONS[@]}"; do "${section}"; done
}

# --edit: one section at a time, against what is already there.
configure_edit() {
  local target="${1:-${ENV_FILE}}"
  load_current "${target}"
  while true; do
    ui_menu "Which settings?" \
      "Version and access|release, bind address, port" \
      "Identity|APP_URL, administrator, your CA" \
      "Secrets and database|storage key, bundled or own MongoDB, licence" \
      "Sign-in|session lifetime, OIDC (LDAP lives in the app)" \
      "Mail|SMTP relay" \
      "Uploads and Jira import|upload limit, import worker" \
      "AI features|the agent scheduler" \
      "Operations|logs, metrics, API browser, egress" \
      "Resource limits|CPU, memory, heaps" \
      "Save and finish|write the changes" \
      "Cancel|leave .env untouched"

    case "${UI_CHOICE}" in
      1) section_version ;;
      2) section_identity ;;
      3) section_secrets ;;
      4) section_signin ;;
      5) section_mail ;;
      6) section_storage ;;
      7) section_ai ;;
      8) section_operations ;;
      9) section_resources ;;
      10) break ;;
      11) note "nothing changed"; return 1 ;;
    esac
  done

  configure_summary
  ui_yesno "Write these to ${target}?" y || { note "nothing changed"; return 1; }

  # Keep the previous file. A reconfigure that loses a working setting is
  # recoverable if the old one is still on disk.
  [ -f "${target}" ] && cp "${target}" "${target}.bak"
  render_env "${target}"
  ok "written"
  return 0
}

load_example_defaults

case "${1:-}" in
  --edit) ui_require_tty; configure_edit ;;
  --edit-candidate)
    # The same menu, against the file the installer is still assembling — used
    # when the live checks reject the configuration itself rather than one of
    # the things it points at.
    ui_require_tty; configure_edit "${2:?usage: --edit-candidate <path>}" ;;
  --collect)
    # For the wizard: ask everything, write to a candidate file, do not confirm
    # and do not touch compose/.env. The installer tests that candidate against
    # the real directory and mail relay before it becomes the configuration.
    ui_require_tty
    configure_all
    configure_summary
    render_env "${2:?usage: --collect <path>}" ;;
  --section)
    # Re-ask one section of a candidate the live checks rejected, so a wrong
    # bind password costs one question rather than all nine.
    ui_require_tty
    load_current "${3:?usage: --section <name> <path>}"
    case "${2:?usage: --section <name> <path>}" in
      version) section_version ;;
      identity) section_identity ;;
      secrets) section_secrets ;;
      signin) section_signin ;;
      mail) section_mail ;;
      storage) section_storage ;;
      ai) section_ai ;;
      operations) section_operations ;;
      resources) section_resources ;;
      *) die "unknown section: $2" ;;
    esac
    render_env "$3" ;;
  --render-only)
    # For the equivalence test: render from whatever is already in .env.
    load_current; render_env "${2:?usage: --render-only <path>}" ;;
  "")
    ui_require_tty
    configure_all
    configure_summary
    ui_yesno "Write this to ${ENV_FILE}?" y || die "nothing written" "Run ./tasksense again when you are ready."
    render_env "${ENV_FILE}"
    ok "written to ${ENV_FILE} (mode 600)"
    ;;
  *) die "unknown option: $1" "Use --edit, or no arguments." ;;
esac
