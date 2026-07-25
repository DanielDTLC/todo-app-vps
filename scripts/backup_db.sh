#!/bin/bash
# Respaldo diario de la base de datos todo_db
# Instalar en cron: 0 3 * * * /var/www/todo-app/scripts/backup_db.sh

BACKUP_DIR="/var/backups/todo_db"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
FILENAME="$BACKUP_DIR/todo_db_$DATE.sql.gz"
RETENTION_DAYS=7

mkdir -p "$BACKUP_DIR"

# Requiere .pgpass configurado o variable PGPASSWORD
pg_dump -U todo_user -h localhost todo_db | gzip > "$FILENAME"

# Eliminar respaldos con más de RETENTION_DAYS días
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup creado: $FILENAME"
