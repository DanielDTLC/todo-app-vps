# Guía de Despliegue: To-Do List en VPS con CI/CD

## 0. Arquitectura

```
[Usuario] --HTTPS--> [Nginx :80/443] --proxy /api--> [Node.js/Express :3000] --> [PostgreSQL :5432]
                          |
                    sirve /frontend (SPA estática)

[GitHub Actions] --push a main--> [SSH + rsync] --> [VPS]
```

- **Web/Reverse proxy:** Nginx (sirve el frontend estático y hace proxy de `/api`).
- **Aplicación:** Node.js + Express, gestionado con PM2 (mantiene el proceso vivo, reinicia ante caídas).
- **Base de datos:** PostgreSQL (local al VPS, no expuesta a internet).
- **CI/CD:** GitHub Actions → SSH + rsync al VPS + `pm2 restart`.

---

## 1. Provisionamiento del VPS (Ubuntu 22.04/24.04)

### 1.1 Acceso inicial y usuario no-root

```bash
ssh root@TU_IP_VPS

adduser deploy
usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy   # copia tu clave SSH
```

Desde ahora, conectate como `ssh deploy@TU_IP_VPS`. Deshabilitá el login root por SSH:

```bash
sudo nano /etc/ssh/sshd_config
# PermitRootLogin no
# PasswordAuthentication no   (usá solo claves SSH)
sudo systemctl restart ssh
```

### 1.2 Firewall (UFW)

```bash
sudo apt update && sudo apt install ufw -y
sudo ufw allow OpenSSH        # puerto 22
sudo ufw allow 'Nginx Full'   # puertos 80 y 443
sudo ufw enable
sudo ufw status verbose
```

Importante: **el puerto 5432 (Postgres) y el 3000 (Node) NO se abren al exterior**, solo se acceden vía `localhost`.

### 1.3 Node.js y PM2

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2
pm2 startup   # habilita que PM2 arranque los procesos al reiniciar el VPS
```

### 1.4 Nginx

```bash
sudo apt install -y nginx
sudo mkdir -p /var/www/todo-app/{frontend,backend}
sudo chown -R deploy:deploy /var/www/todo-app

# copiar nginx/todo-app.conf a:
sudo cp todo-app.conf /etc/nginx/sites-available/todo-app
sudo ln -s /etc/nginx/sites-available/todo-app /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default   # opcional
sudo nginx -t && sudo systemctl reload nginx
```

### 1.5 PostgreSQL

```bash
sudo apt install -y postgresql postgresql-contrib
sudo -u postgres psql

-- Dentro de psql:
CREATE USER todo_user WITH PASSWORD 'una_password_segura';
CREATE DATABASE todo_db OWNER todo_user;
\q
```

Cargar el esquema:
```bash
psql -U todo_user -h localhost -d todo_db -f backend/schema.sql
```

### 1.6 HTTPS (opcional pero recomendado)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d tu-dominio.com
```

---

## 2. Variables de entorno del backend

Crear `/var/www/todo-app/backend/.env` (este archivo **no** se sube a git ni se sincroniza por rsync):

```
DB_HOST=localhost
DB_PORT=5432
DB_USER=todo_user
DB_PASSWORD=una_password_segura
DB_NAME=todo_db
PORT=3000
```

Primer arranque manual:
```bash
cd /var/www/todo-app/backend
npm install --omit=dev
pm2 start server.js --name todo-api
pm2 save
```

---

## 3. Pipeline CI/CD (GitHub Actions)

El workflow está en `.github/workflows/deploy.yml`. Funciona así:

1. **Trigger:** push a la rama `main`.
2. **Checkout:** GitHub Actions clona el repo.
3. **SSH:** se configura una clave privada (guardada como *secret*) para conectarse al VPS.
4. **rsync:** sincroniza `backend/` y `frontend/` al VPS (sin subir `node_modules` ni `.env`).
5. **Post-deploy:** por SSH se ejecuta `npm install` y `pm2 restart todo-api` (o `pm2 start` si es la primera vez).
6. **Health check:** valida que `/api/health` responda 200 antes de dar el deploy por exitoso.

### 3.1 Configurar los Secrets en GitHub

En el repo: **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Valor |
|---|---|
| `VPS_HOST` | IP o dominio del VPS |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Clave privada SSH (par generado solo para CI/CD, sin passphrase) |

Generar el par de claves dedicado para CI/CD:
```bash
ssh-keygen -t ed25519 -f deploy_key -C "github-actions" -N ""
# Copiar deploy_key.pub al VPS:
ssh-copy-id -i deploy_key.pub deploy@TU_IP_VPS
# Pegar el contenido de deploy_key (privada) en el secret VPS_SSH_KEY
```

Con esto, cada `git push` a `main` dispara el deploy automáticamente, sin intervención manual.

---

## 4. Backups y mantenimiento

### 4.1 Backup automático de la base de datos

Script: `scripts/backup_db.sh`. Programarlo con cron:

```bash
crontab -e
# Agregar:
0 3 * * * /var/www/todo-app/scripts/backup_db.sh >> /var/log/todo_backup.log 2>&1
```

Esto genera un dump comprimido diario en `/var/backups/todo_db`, con retención de 7 días. Idealmente, copiar también esos dumps fuera del VPS (ej. a S3, otro servidor, o descargarlos periódicamente) para no perder los datos si el VPS falla completamente.

### 4.2 Logs

```bash
pm2 logs todo-api            # logs de la aplicación
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### 4.3 Seguridad adicional (opcional, suma puntos en "Excelente")

```bash
sudo apt install -y fail2ban   # bloquea intentos de fuerza bruta por SSH
sudo apt install -y unattended-upgrades  # parches de seguridad automáticos
```

---

## 5. Checklist para el informe

- [ ] Diagrama de red (usar el de la sección 0, o graficarlo)
- [ ] Bitácora: comandos ejecutados, puertos abiertos (22, 80, 443), usuario `deploy` sin privilegios root directos
- [ ] Capturas del pipeline corriendo en GitHub Actions (pestaña "Actions")
- [ ] Capturas de la app funcionando (CRUD + filtro) en la IP/dominio del VPS
- [ ] Explicación del script de backup y su cron
- [ ] `sudo ufw status verbose` como evidencia del firewall
