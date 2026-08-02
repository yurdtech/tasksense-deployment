#!/usr/bin/env bash
#
# The configuration step: every setting, asked in order, with what it does.
#
#   scripts/wizard/configure.sh           ask everything, write compose/.env
#   scripts/wizard/configure.sh --edit    change one section of an existing .env
#
# This is docs/04-CONFIGURATION.md turned inside out. The reference answers
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

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

EXAMPLE_FILE="${COMPOSE_DIR}/.env.example"
declare -A ANSWER=()
declare -A EXAMPLE_DEFAULT=()

# ── the answer set ───────────────────────────────────────────────────────────

cfg_set() { ANSWER["$1"]="$2"; }
cfg_get() { printf '%s' "${ANSWER[$1]-}"; }
cfg_has() { [ -n "${ANSWER[$1]+set}" ]; }

# Whatever the example suggests becomes the offered default, so the two files
# cannot drift: change .env.example and the wizard follows.
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
    EXAMPLE_DEFAULT["${key}"]="${value}"
  done < "${EXAMPLE_FILE}"
}

example_default() { printf '%s' "${EXAMPLE_DEFAULT[$1]-}"; }

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
            if cfg_has "${key}"; then
              if [ -n "$(cfg_get "${key}")" ]; then
                rendered="${key}=$(cfg_get "${key}")"
              else
                # An empty answer means "leave it unset". Keep the example's
                # commented line so the setting is still documented in place.
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

# ── section 1: version and access ────────────────────────────────────────────

section_version() {
  ui_step 1 9 "Version and access"
  ui_text "Which release to run, and where it listens on this host."

  ui_ask "TASKSENSE_VERSION" "$(example_default TASKSENSE_VERSION)" \
    "Pin it explicitly. Never \"latest\": a restart would then silently move you to a different version, which turns an unrelated reboot into an unplanned upgrade."
  cfg_set TASKSENSE_VERSION "${UI_VALUE}"

  printf '\n'
  ui_text "TaskSense listens on this host, and a reverse proxy in front of it terminates TLS."
  ui_ask "BIND_ADDRESS" "$(example_default BIND_ADDRESS)" \
    "127.0.0.1 means only this machine can connect — correct when the proxy runs here. Use 0.0.0.0 only if the proxy is on another host, and then firewall the port."
  cfg_set BIND_ADDRESS "${UI_VALUE}"

  ui_ask "HTTP_PORT" "$(example_default HTTP_PORT)" \
    "The port on this host. Change it if something else already uses 3000." ui_valid_port
  cfg_set HTTP_PORT "${UI_VALUE}"
}

# ── section 2: identity ──────────────────────────────────────────────────────

section_identity() {
  ui_step 2 9 "This installation's identity"

  ui_ask "APP_URL" "$(example_default APP_URL)" \
    "The address users type, including https://. Sign-in redirects are built from it, so a wrong value breaks SSO in a way that is hard to trace: the login page appears, and the return trip lands nowhere." ui_valid_url
  cfg_set APP_URL "${UI_VALUE}"

  # Same host for UI and API is the normal case, and typing it twice is how the
  # two drift apart.
  cfg_set CORS_ALLOWED_ORIGINS "$(cfg_get APP_URL)"
  ok "CORS_ALLOWED_ORIGINS set to the same address"
  ui_hint "Change it by hand only if the UI is served from a different origin than the API."

  printf '\n'
  ui_ask "FIRST_ADMIN_EMAIL" "" \
    "Becomes the administrator of the new, empty workspace. No password is set for it — sign in through your identity provider, or register with this address to choose one. There is no default credential to change afterwards." ui_valid_email
  cfg_set FIRST_ADMIN_EMAIL "${UI_VALUE}"
}

# ── section 3: secrets ───────────────────────────────────────────────────────

section_secrets() {
  ui_step 3 9 "Secrets"
  ui_text "Two values that must be generated rather than chosen. Both go into your password manager, and both belong with the database backup."

  ui_secret "STORAGE_SECRET" \
    "Encrypts stored credentials at rest — object-storage keys, model API keys. Changing it later makes those unreadable and they have to be re-entered by hand. A restore without this value restores unusable credentials, so back it up WITH the database, not instead of it." 32
  cfg_set STORAGE_SECRET "${UI_VALUE}"

  printf '\n'
  ui_text "TaskSense stores everything in MongoDB. The installation can bring its own, or use one you already run."
  ui_menu "Which database?" \
    "Bring one with it|a MongoDB container beside the application — most installations" \
    "Use my own|an existing cluster, a replica set, or a server your DBAs run"

  if [ "${UI_CHOICE}" = "2" ]; then
    printf '\n'
    ui_text "Then TaskSense will not start a database of its own. Give it the connection string; the account in it needs read and write on one database, and TaskSense creates its own collections and indexes there on first start."
    ui_ask "MONGODB_URI" "mongodb://tasksense:PASSWORD@mongo.bank.internal:27017/?authSource=admin" \
      "TLS and replica-set options belong in the URI: ?replicaSet=rs0&tls=true&tlsCAFile=/certs/ca.pem&authSource=admin. Percent-encode anything in the password that a URI reads as structure — / : @ ? # [ ] % — or the driver refuses the whole string."
    cfg_set MONGODB_URI "${UI_VALUE}"

    # Not used with an external database, and leaving the example's values would
    # suggest an account somebody should create.
    cfg_set MONGO_USER ""
    cfg_set MONGO_PASSWORD ""
    ui_hint "The bundled database will not be started, and its backup is then your DBAs' — ./scripts/backup.sh covers files and configuration but cannot reach a database it does not run. docs/07-BACKUP-DR.md."
  else
    cfg_set MONGODB_URI ""
    ui_ask "MONGO_USER" "$(example_default MONGO_USER)" \
      "The database account the application uses. It is created on first start."
    cfg_set MONGO_USER "${UI_VALUE}"

    ui_secret "MONGO_PASSWORD" \
      "The password for that account. Generated is better than chosen — nothing types it by hand, so there is no reason for it to be memorable. It ends up inside a connection string, so it is drawn from hex: a / or + or = would end the password early and the database would be unreachable before the first query." 24 uri
    cfg_set MONGO_PASSWORD "${UI_VALUE}"
  fi

  printf '\n'
  ui_text "A licence lifts two limits: the 10-account cap and the 500-a-month automation allowance. Everything else in TaskSense is the same either way — there is no feature behind it."
  if ui_yesno "Do you have a licence key?" n; then
    ui_ask "LICENSE_KEY" "" \
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
  ui_text "Pick one primary method. Local passwords stay available whichever you choose, and you should keep at least one local administrator — otherwise an identity-provider outage locks you out of your own instance."

  ui_menu "How will people sign in?" \
    "Active Directory / LDAP|the usual answer inside a bank" \
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

signin_ldap() {
  printf '\n'
  ui_text "Six settings. The wizard tests them against your real directory before anything is installed, so a wrong bind DN is caught here rather than by the first person who cannot sign in."

  ui_ask "LDAP_URL" "$(example_default LDAP_URL)" \
    "Your domain controller. ldaps:// only — a plain ldap:// bind sends the service account password across the network in clear text, and on-premise the application refuses it." ui_valid_ldap_url
  cfg_set LDAP_URL "${UI_VALUE}"

  ui_ask "LDAP_BIND_DN" "$(example_default LDAP_BIND_DN)" \
    "A read-only service account. It looks users up; it never needs to write, and it should not be a domain administrator."
  cfg_set LDAP_BIND_DN "${UI_VALUE}"

  ui_secret "LDAP_BIND_PASSWORD" "The service account's password. Type it — this one is not ours to generate." 0
  cfg_set LDAP_BIND_PASSWORD "${UI_VALUE}"

  ui_ask "LDAP_BASE_DN" "$(example_default LDAP_BASE_DN)" \
    "Where the search starts. Narrower is faster and safer: point it at the OU that holds staff rather than the top of the domain."
  cfg_set LDAP_BASE_DN "${UI_VALUE}"

  ui_ask "LDAP_USER_FILTER" "$(example_default LDAP_USER_FILTER)" \
    "How a typed username becomes a directory entry. {{username}} is replaced with what the user typed. sAMAccountName is right for Active Directory; uid for OpenLDAP."
  cfg_set LDAP_USER_FILTER "${UI_VALUE}"

  printf '\n'
  if ui_yesno "Is the directory certificate issued by your own CA?" y; then
    ui_ask "LDAP_TLS_CA" "$(example_default LDAP_TLS_CA)" \
      "The path INSIDE the container. Copy the CA file into compose/certs/ on this host — that directory is mounted at /certs, read-only — and leave this as /certs/<filename>."
    cfg_set LDAP_TLS_CA "${UI_VALUE}"
    check_ca_present "${UI_VALUE}"
  fi

  printf '\n'
  if ui_yesno "Map directory groups to TaskSense roles?" y; then
    ui_ask "LDAP_GROUP_MAP" "$(example_default LDAP_GROUP_MAP)" \
      "group DN=role, separated by semicolons. Re-evaluated at every sign-in, so removing somebody from the group in AD takes effect on their next login — you do not have to touch TaskSense."
    cfg_set LDAP_GROUP_MAP "${UI_VALUE}"
  fi
}

# The path just given is the one inside the container; the file has to be on
# this host, in compose/certs. Those are two different things and the setting
# only mentions one of them, which is why "I put the certificate on the server"
# and "the application can read the certificate" come apart so easily.
#
# Checking here rather than leaving it to the live checks costs nothing and
# arrives while the operator still has the file path in their head.
check_ca_present() {
  local inside="$1" name
  case "${inside}" in
    /certs/*) name="${inside#/certs/}" ;;
    *)
      warn "that path is not under /certs, so the compose file will not mount it"
      ui_hint "Only compose/certs is mounted into the container. A path anywhere else needs a mount you add yourself — docs/05-IDENTITY.md."
      return 0
      ;;
  esac

  if [ -f "${COMPOSE_DIR}/certs/${name}" ]; then
    ok "found ${COMPOSE_DIR}/certs/${name}"
    return 0
  fi

  warn "there is no ${name} in ${COMPOSE_DIR}/certs"
  ui_text "The path above is correct for inside the container — but the file has to exist on this host for the container to see it:"
  ui_hint "  cp /etc/ssl/certs/${name} ${COMPOSE_DIR}/certs/"
  ui_hint "The live checks will refuse to pass until it is there, so this can be done now or in a moment."
}

signin_oidc() {
  printf '\n'
  ui_ask "OIDC_ISSUER" "$(example_default OIDC_ISSUER)" \
    "The issuer URL. Discovery must work from this host: the wizard fetches its .well-known/openid-configuration to check."
  cfg_set OIDC_ISSUER "${UI_VALUE}"

  ui_ask "OIDC_CLIENT_ID" "$(example_default OIDC_CLIENT_ID)" "The client you registered at the provider."
  cfg_set OIDC_CLIENT_ID "${UI_VALUE}"

  ui_secret "OIDC_CLIENT_SECRET" "The client secret from the provider." 0
  cfg_set OIDC_CLIENT_SECRET "${UI_VALUE}"

  local redirect
  redirect="$(cfg_get APP_URL)/api/v1/auth/oidc/callback"
  cfg_set OIDC_REDIRECT_URI "${redirect}"
  ok "OIDC_REDIRECT_URI: ${redirect}"
  ui_hint "Register that exact URI at the provider — a mismatch is the single most common OIDC failure, and the error it produces names the provider, not us."

  printf '\n'
  ui_ask "OIDC_LABEL" "$(example_default OIDC_LABEL)" "The wording on the sign-in button."
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

  ui_ask "SMTP_HOST" "$(example_default SMTP_HOST)" "Your internal relay."
  cfg_set SMTP_HOST "${UI_VALUE}"

  ui_ask "SMTP_PORT" "$(example_default SMTP_PORT)" \
    "25 for an internal relay that does not authenticate, 587 for submission with STARTTLS, 465 for implicit TLS." ui_valid_port
  cfg_set SMTP_PORT "${UI_VALUE}"

  if [ "$(cfg_get SMTP_PORT)" = "465" ]; then
    cfg_set SMTP_SECURE true
  else
    cfg_set SMTP_SECURE false
  fi
  ok "SMTP_SECURE=$(cfg_get SMTP_SECURE)"
  ui_hint "true means TLS from the first byte (465). On 587 the connection starts plain and upgrades, which is still encrypted."

  printf '\n'
  if ui_yesno "Does the relay require a username and password?" n; then
    ui_ask "SMTP_USER" "" "The account TaskSense authenticates as."
    cfg_set SMTP_USER "${UI_VALUE}"
    ui_secret "SMTP_PASS" "Its password." 0
    cfg_set SMTP_PASS "${UI_VALUE}"
  fi

  printf '\n'
  ui_ask "EMAIL_FROM" "$(example_default EMAIL_FROM)" \
    "The From address. Many relays refuse mail from an address they do not own, so use one in your own domain."
  cfg_set EMAIL_FROM "${UI_VALUE}"
}

# ── section 6: file storage ──────────────────────────────────────────────────

section_storage() {
  ui_step 6 9 "File storage"
  ui_text "Attachments go to the container's data volume by default. That suits most installations — back it up together with the database. Shared or replicated storage is configured later from Admin → Storage, not here."

  ui_ask "STORAGE_MAX_FILE_MB" "$(example_default STORAGE_MAX_FILE_MB)" \
    "Per-file upload ceiling, in megabytes."
  cfg_set STORAGE_MAX_FILE_MB "${UI_VALUE}"

  warn "set the same limit on your reverse proxy"
  ui_hint "nginx: client_max_body_size ${UI_VALUE}m — otherwise a large upload is rejected by the proxy before it ever reaches TaskSense, and the message the user sees comes from nginx."
}

# ── section 7: AI ────────────────────────────────────────────────────────────

section_ai() {
  ui_step 7 9 "AI features"
  ui_text "Off unless you turn them on, and everything else works without them. When enabled they talk to an OpenAI-compatible endpoint running INSIDE your network — vLLM, Ollama, or a gateway — configured from Admin → Agents → Providers. Nothing is sent outside."

  if ! ui_yesno "Enable the AI features?" n; then
    cfg_set AGENT_EXECUTOR off
    cfg_set AGENT_DISPATCHER off
    ok "off — you can turn them on later without reinstalling"
    return 0
  fi

  cfg_set AGENT_DISPATCHER on
  ok "AGENT_DISPATCHER=on — the scheduler that advances agent tasks"

  printf '\n'
  ui_text "The agent executor runs model-authored commands in a sandboxed workspace. It stays off unless you have read what it does and decided you want it."
  if ui_yesno "Enable the agent executor as well?" n; then
    cfg_set AGENT_EXECUTOR on
  else
    cfg_set AGENT_EXECUTOR off
  fi
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
  if ui_yesno "Expose Prometheus metrics?" n; then
    cfg_set METRICS_ENABLED 1
    cfg_set METRICS_TOKEN "$(openssl rand -hex 32)"
    ok "metrics at $(cfg_get APP_URL)/api/v1/metrics"
    ui_hint "The endpoint requires a bearer token, which has been generated. It is in .env as METRICS_TOKEN — put it in your Prometheus scrape config."
  fi

  printf '\n'
  ui_text "Some installations need TaskSense to reach other internal systems: a self-hosted GitLab, an internal Jira. Everything not listed is refused, including private and link-local addresses — which is what stops a webhook URL entered in the admin console from being used to probe your network."
  if ui_yesno "Allow outbound calls to specific internal hosts?" n; then
    ui_ask "EGRESS_ALLOWLIST" "$(example_default EGRESS_ALLOWLIST)" \
      "Hostnames, comma-separated. No scheme, no path."
    cfg_set EGRESS_ALLOWLIST "${UI_VALUE}"
  fi
}

# ── section 9: resources ─────────────────────────────────────────────────────

section_resources() {
  ui_step 9 9 "Resource limits"
  ui_text "From docs/11-SIZING.md. \"Users\" means people with accounts — about a fifth of a team is active at once, and concurrency is what actually costs resources."

  ui_menu "How many people will have accounts?" \
    "Up to 50|2 cores, 4 GB, 20 GB disk" \
    "Up to 200|4 cores, 8 GB, 100 GB SSD" \
    "Up to 1000|8 cores, 16 GB, 500 GB SSD" \
    "Keep the defaults|2 cores and 2 GB each"

  # Memory splits roughly in half between the application and MongoDB.
  case "${UI_CHOICE}" in
    1) cfg_set APP_CPU_LIMIT 1; cfg_set APP_MEMORY_LIMIT 2g
       cfg_set MONGO_CPU_LIMIT 1; cfg_set MONGO_MEMORY_LIMIT 2g ;;
    2) cfg_set APP_CPU_LIMIT 2; cfg_set APP_MEMORY_LIMIT 4g
       cfg_set MONGO_CPU_LIMIT 2; cfg_set MONGO_MEMORY_LIMIT 4g ;;
    3) cfg_set APP_CPU_LIMIT 4; cfg_set APP_MEMORY_LIMIT 8g
       cfg_set MONGO_CPU_LIMIT 4; cfg_set MONGO_MEMORY_LIMIT 8g
       note "at this size consider a replica set and shared object storage — docs/11-SIZING.md" ;;
    *) ;;
  esac
  ok "app: $(cfg_get APP_CPU_LIMIT) cores / $(cfg_get APP_MEMORY_LIMIT)   mongo: $(cfg_get MONGO_CPU_LIMIT) cores / $(cfg_get MONGO_MEMORY_LIMIT)"
}

# ── review ───────────────────────────────────────────────────────────────────

configure_summary() {
  UI_SUMMARY=()
  ui_summary_add "Version" "$(cfg_get TASKSENSE_VERSION)"
  ui_summary_add "Address" "$(cfg_get APP_URL)"
  ui_summary_add "Listens on" "$(cfg_get BIND_ADDRESS):$(cfg_get HTTP_PORT)"
  ui_summary_add "Administrator" "$(cfg_get FIRST_ADMIN_EMAIL)"
  ui_summary_secret "Storage secret" "$(cfg_get STORAGE_SECRET)"
  if [ -n "$(cfg_get MONGODB_URI)" ]; then
    # The URI carries the password; the summary must not.
    ui_summary_add "Database" "your own — $(printf '%s' "$(cfg_get MONGODB_URI)" | sed 's|://[^@]*@|://…@|')"
  else
    ui_summary_add "Database" "bundled container"
    ui_summary_add "Database user" "$(cfg_get MONGO_USER)"
    ui_summary_secret "Database password" "$(cfg_get MONGO_PASSWORD)"
  fi

  if [ -n "$(cfg_get LDAP_URL)" ]; then
    ui_summary_add "Sign-in" "LDAP — $(cfg_get LDAP_URL)"
  elif [ -n "$(cfg_get OIDC_ISSUER)" ]; then
    ui_summary_add "Sign-in" "OIDC — $(cfg_get OIDC_ISSUER)"
  else
    ui_summary_add "Sign-in" "local passwords"
  fi

  if [ -n "$(cfg_get SMTP_HOST)" ]; then
    ui_summary_add "Mail" "$(cfg_get SMTP_HOST):$(cfg_get SMTP_PORT)"
  else
    ui_summary_add "Mail" "not configured — notifications stay in-app"
  fi

  ui_summary_add "AI features" "$([ "$(cfg_get AGENT_DISPATCHER)" = "on" ] && echo "on" || echo "off")"
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
      "Identity|APP_URL, administrator" \
      "Secrets|storage key, database password, licence" \
      "Sign-in|LDAP, OIDC, local passwords" \
      "Mail|SMTP relay" \
      "File storage|upload limit" \
      "AI features|agents and the scheduler" \
      "Operations|logs, metrics, egress" \
      "Resource limits|CPU and memory" \
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
