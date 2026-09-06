# certs

Anything in this directory is visible inside the container at `/certs`,
read-only. It is mounted by `docker-compose.yml`.

Put your internal CA here when the **mail relay** uses a certificate your
organisation issued:

```bash
cp /etc/ssl/certs/bank-ca.pem compose/certs/
```

The path you then reference in `.env` is the path **inside** the container
(`/certs/bank-ca.pem`), not on this host. That is the usual mistake, and it
fails at first use rather than at startup.

The **directory (LDAP)** CA does not go here: LDAP is configured inside the
application (Admin → Authentication), where the CA certificate is pasted as
PEM text — no file on the server, no mount, no restart.

Certificates are public by nature; private keys do not belong here. TLS for
the address users type is terminated by your reverse proxy, not by TaskSense —
see `examples/nginx.conf`.
