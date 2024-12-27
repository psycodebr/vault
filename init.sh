#!/bin/sh
set -e

echo "Verificando dependências..."
command -v wget > /dev/null || { echo "Erro: wget não está instalado."; exit 1; }
command -v vault > /dev/null || { echo "Erro: vault CLI não está instalado."; exit 1; }

echo "Aguardando o Vault iniciar..."
export VAULT_ADDR=http://vault:8200

MAX_RETRIES=10
RETRY_COUNT=0

until wget -qO- $VAULT_ADDR/v1/sys/health | grep '"sealed":false' > /dev/null; do
  echo "Vault ainda não está acessível, aguardando..."
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "Erro: Vault não ficou acessível após $MAX_RETRIES tentativas."
    exit 1
  fi
  sleep 2
done
echo "Vault está acessível, iniciando configuração..."

# Logar no Vault
vault login root || { echo "Erro ao logar no Vault"; exit 1; }

# Criar e configurar Policy
echo "Configurando policy para o Vault Agent..."
vault policy write vault-agent-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read", "list"]
}
EOF

# Criar e configurar AppRole
echo "Configurando AppRole para o Vault Agent..."
vault auth enable approle || { echo "Erro ao habilitar AppRole"; exit 1; }
vault write auth/approle/role/vault-agent-role \
  token_policies="vault-agent-policy" || { echo "Erro ao configurar AppRole"; exit 1; }
vault read -field=role_id auth/approle/role/vault-agent-role/role-id > /vault/role_id || { echo "Erro ao obter role_id"; exit 1; }
vault write -f -field=secret_id auth/approle/role/vault-agent-role/secret-id > /vault/secret_id || { echo "Erro ao obter secret_id"; exit 1; }

# Adicionar segredos no Vault
echo "Adicionando segredos no Vault..."
vault kv put secret/wordpress \
  WORDPRESS_DB_HOST=mariadb \
  WORDPRESS_DB_USER=wordpress_user \
  WORDPRESS_DB_PASSWORD=wordpress_pass \
  WORDPRESS_DB_NAME=wordpress_db \
  WORDPRESS_REDIS_HOST=redis \
  AWS_ACCESS_KEY_ID=minio_access_key \
  AWS_SECRET_ACCESS_KEY=minio_secret_key \
  AWS_BUCKET_NAME=wordpress-bucket \
  S3_URL=http://minio:9000 || { echo "Erro ao adicionar segredos no Vault"; exit 1; }

vault kv put secret/db \
  MYSQL_ROOT_PASSWORD=root_pass \
  MYSQL_DATABASE=wordpress_db \
  MYSQL_USER=wordpress_user \
  MYSQL_PASSWORD=wordpress_pass || { echo "Erro ao adicionar segredos no Vault"; exit 1; }

# Criar diretórios e arquivos necessários
echo "Criando diretórios e arquivos necessários..."
mkdir -p /etc/vault /vault
touch /vault/role_id /vault/secret_id /etc/vault/config.hcl /etc/vault/secrets-template.tpl

# Criar arquivos de configuração
cat <<EOF > /etc/vault/config.hcl
pid_file = "/var/run/vault-agent-pid"

auto_auth {
  method "approle" {
    config = {
      role_id_file_path = "/vault/role_id"
      secret_id_file_path = "/vault/secret_id"
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets.json"
    }
  }
}

template {
  source      = "/etc/vault/secrets-template.tpl"
  destination = "/vault/secrets.env"
}
EOF

cat <<EOF > /etc/vault/secrets-template.tpl
WORDPRESS_DB_HOST={{ with secret "secret/data/wordpress" }}{{ .Data.data.WORDPRESS_DB_HOST }}{{ end }}
WORDPRESS_DB_USER={{ with secret "secret/data/wordpress" }}{{ .Data.data.WORDPRESS_DB_USER }}{{ end }}
WORDPRESS_DB_PASSWORD={{ with secret "secret/data/wordpress" }}{{ .Data.data.WORDPRESS_DB_PASSWORD }}{{ end }}
WORDPRESS_DB_NAME={{ with secret "secret/data/wordpress" }}{{ .Data.data.WORDPRESS_DB_NAME }}{{ end }}
WORDPRESS_REDIS_HOST={{ with secret "secret/data/wordpress" }}{{ .Data.data.WORDPRESS_REDIS_HOST }}{{ end }}
AWS_ACCESS_KEY_ID={{ with secret "secret/data/wordpress" }}{{ .Data.data.AWS_ACCESS_KEY_ID }}{{ end }}
AWS_SECRET_ACCESS_KEY={{ with secret "secret/data/wordpress" }}{{ .Data.data.AWS_SECRET_ACCESS_KEY }}{{ end }}
AWS_BUCKET_NAME={{ with secret "secret/data/wordpress" }}{{ .Data.data.AWS_BUCKET_NAME }}{{ end }}
S3_URL={{ with secret "secret/data/wordpress" }}{{ .Data.data.S3_URL }}{{ end }}
MYSQL_ROOT_PASSWORD={{ with secret "secret/data/db" }}{{ .Data.data.MYSQL_ROOT_PASSWORD }}{{ end }}
MYSQL_DATABASE={{ with secret "secret/data/db" }}{{ .Data.data.MYSQL_DATABASE }}{{ end }}
MYSQL_USER={{ with secret "secret/data/db" }}{{ .Data.data.MYSQL_USER }}{{ end }}
MYSQL_PASSWORD={{ with secret "secret/data/db" }}{{ .Data.data.MYSQL_PASSWORD }}{{ end }}
EOF

# Iniciar o Vault Agent como processo principal
echo "Iniciando o Vault Agent..."
exec vault agent -config=/etc/vault/config.hcl -log-level=debug
