# certs

Anything in this directory is visible inside the application containers (app,
worker, migrate) at `/certs`, read-only. It is mounted by `docker-compose.yml`
and ships empty.

Put your internal CA here when anything TaskSense connects to uses a
certificate your organisation issued — your own MongoDB over TLS, the SMTP
relay, the OIDC identity provider, an internal LLM gateway:

```bash
cp /etc/pki/ca-trust/source/anchors/corp-ca.pem compose/certs/
chmod 644 compose/certs/corp-ca.pem
```

Then name it in `.env` by its path **inside** the container — `/certs/…`, not
the path on this host. That is the usual mistake, and it fails at first use
rather than at startup:

```bash
# Every outbound TLS connection the application makes trusts this bundle:
NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem

# MongoDB reads its CA from the connection string:
MONGODB_URI=mongodb://…/?replicaSet=rs0&tls=true&tlsCAFile=/certs/corp-ca.pem&authSource=admin
```

`scripts/preflight.sh` checks that both files exist here. A bundle with
several certificates (root plus intermediates) in one PEM file is fine.

The **directory (LDAP)** CA does not go here: LDAP is configured inside the
application (Admin → Authentication), where the CA certificate is pasted as
PEM text — no file on the server, no mount, no restart.

Certificates are public by nature; private keys do not belong here. TLS for
the address users type is terminated by your reverse proxy, not by TaskSense —
see `examples/nginx.conf`.
