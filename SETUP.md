# Setup — Users CRUD at http://crud.local

Everything is already written and `npm install` has run. What remains are the
four steps that need `sudo`.

## 1. Create the database, user and table

```bash
sudo mysql --defaults-file=/etc/mysql/debian.cnf < /var/www/your_domain/crud/schema.sql
```

This creates the `crud_db` database, the `crud_user`/`CHANGE_ME_StrongPass#1` MySQL account,
the `users` table, and three sample rows. Credentials live in `.env` — change
both files together if you want different ones.

Verify:

```bash
mysql -u crud_user -p'CHANGE_ME_StrongPass#1' crud_db -e "SELECT id, name, email FROM users;"
```

## 2. Point crud.local at your machine

```bash
echo "127.0.0.1	crud.local" | sudo tee -a /etc/hosts
```

## 3. Enable the Apache reverse proxy

Apache cannot run Node directly, so it proxies `crud.local` to Node on port 3000.

```bash
sudo cp /var/www/your_domain/crud/deploy/crud.local.conf /etc/apache2/sites-available/
sudo a2enmod proxy proxy_http headers
sudo a2ensite crud.local
sudo apache2ctl configtest
sudo systemctl reload apache2
```

## 4. Run the Node app

For development, in a terminal you keep open:

```bash
cd /var/www/your_domain/crud
npm start
```

To run it as a background service that survives reboots instead:

```bash
sudo cp /var/www/your_domain/crud/deploy/crud.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now crud
systemctl status crud
```

## 5. Open it

<http://crud.local>

---

## Routes

| Method | Path                 | Purpose               |
|--------|----------------------|-----------------------|
| GET    | `/`                  | List + search users   |
| GET    | `/users/new`         | Create form           |
| POST   | `/users`             | Create user           |
| GET    | `/users/:id/edit`    | Edit form             |
| POST   | `/users/:id`         | Update user           |
| POST   | `/users/:id/delete`  | Delete user           |
| GET    | `/api/users`         | JSON list             |
| GET    | `/api/users/:id`     | JSON single user      |
| GET    | `/health`            | App + DB health check |

## Troubleshooting

- **502 Proxy Error** — Node isn't running. Start it with `npm start`, or check
  `systemctl status crud` / `journalctl -u crud -n 50`.
- **500 "Access denied for user 'crud_user'"** — step 1 hasn't run, or `.env`
  doesn't match the credentials in `schema.sql`.
- **crud.local won't resolve** — step 2 is missing; confirm with
  `grep crud.local /etc/hosts`.
- **Apache serves the wrong site** — another vhost is claiming the request.
  Check `apache2ctl -S` to see which `ServerName` matched.
- Node binds to `127.0.0.1:3000` only, so port 3000 is not reachable from
  outside this machine — all traffic goes through Apache.
