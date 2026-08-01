# certs

Anything in this directory is visible inside the container at `/certs`,
read-only. It is mounted by `docker-compose.yml`.

Put your internal CA here when the directory or the mail relay uses a
certificate your organisation issued:

```bash
cp /etc/ssl/certs/bank-ca.pem compose/certs/
```

Then, in `.env`:

```
LDAP_TLS_CA=/certs/bank-ca.pem
```

The path in `.env` is the path **inside** the container, not on this host.
That is the usual mistake, and it fails at sign-in rather than at startup —
the guided installer (`./tasksense`) tests it before installing for exactly
that reason.

Certificates are public by nature; private keys do not belong here. TLS for
the address users type is terminated by your reverse proxy, not by TaskSense —
see `examples/nginx.conf`.
