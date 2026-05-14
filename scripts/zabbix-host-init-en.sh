#!/bin/bash
########################################################################################################################
###### Installation script for Zabbix, executed by the zabbix-init service, defined in docker-compose.yml #############
########################################################################################################################

#──── Exit on error, e=exit on error, u=exit on undefined var ──────────
set -eu
#──── Flag to determine if a new user should be created with API_WEB_USER and API_WEB_PASS from .env *** DO NOT CHANGE THE VALUE *** ──────────
flag_new_user=FALSE           

#############################################################################################################
#######################################    0. IS API AVAILABLE?   ###########################################
#############################################################################################################
echo "⏳ Esperando que Zabbix API esté disponible..."
MAX_RETRIES=10      
COUNT=0

until curl -sf -o /dev/null -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}'; do
  
  COUNT=$((COUNT + 1))
  
  if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
    echo "❌ API no disponible después de $MAX_RETRIES intentos, saliendo..."
    exit 1
  fi
  
  echo "⏳ Intento $COUNT/$MAX_RETRIES — reintentando en 5 segundos..."
  sleep 5
done

echo "✅ API disponible"
#############################################################################################################
##########################################    1. AUTHENTICATE   #############################################
#############################################################################################################

echo "🔒 Autenticando con usuario por defecto..."
TOKEN=$(curl -sf -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$DEFAULT_USER\",\"password\":\"$DEFAULT_PASS\"},\"id\":1}" \
  | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "⚠️  Fallo la autenticacion con el usuario por defecto, intentando con el usuario '$API_WEB_USER' definido en .env..."
  TOKEN=$(curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$API_WEB_USER\",\"password\":\"$API_WEB_PASS\"},\"id\":1}" \
    | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

  if [ -z "$TOKEN" ]; then
    echo "❌ Error: no se pudo autenticar con ningún usuario, saliendo..."
    exit 1
  fi
  echo "   - 🔑 Autenticado con usuario .env: $API_WEB_USER"
else
  echo "   - 🔑 Autenticado con usuario por defecto: $DEFAULT_USER"
  flag_new_user=TRUE
fi
echo "   - 🔑 Token obtenido: $TOKEN"

#############################################################################################################
###############################    2. GET OR CREATE HOST GROUP    ############################################
#############################################################################################################

GROUP_ID=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"filter\":{\"name\":[\"$HOST_GROUP\"]},\"output\":[\"groupid\"]},\"id\":1}" \
  | grep -o '"groupid":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$GROUP_ID" ]; then
  echo "📁 Creando grupo: $HOST_GROUP"
  GROUP_ID=$(curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.create\",\"params\":{\"name\":\"$HOST_GROUP\"},\"id\":3}" \
    | grep -o '"groupids":\["[^"]*"' | cut -d'"' -f4)
else
  echo "📁 El grupo \"$HOST_GROUP\" ya existe."
fi
echo "   - 📁 Groupname: '$HOST_GROUP' ID: $GROUP_ID"

#############################################################################################################
#####################################    3. GET TEMPLATE ID   ###############################################
#############################################################################################################

TEMPLATE_ID=$(curl -sf -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"host\":[\"$HOST_TEMPLATE\"]}},\"id\":4}" \
  | grep -o '"templateid":"[^"]*"' | head -1 | cut -d'"' -f4)

# ── 3.1. Validate TEMPLATE_ID ─────────────────────────────────
if [ -z "$TEMPLATE_ID" ]; then
  echo "❌ Template '$HOST_TEMPLATE' no encontrado, saliendo..."
  exit 1
fi

echo "📋 '$HOST_TEMPLATE' template ID: $TEMPLATE_ID"

#############################################################################################################
#############################    4. CHECK IF HOST EXISTS   ##################################################
#############################################################################################################

HOST_ID=$(curl -sf -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$HOST_NAME\"]}},\"id\":5}" \
  | grep -o '"hostid":"[^"]*"' | head -1 | cut -d'"' -f4)

# ── 4.1. If host exists — update interface ──────────────────────────────
if [ -n "$HOST_ID" ]; then
  echo "🔄 Host ya existe (ID: $HOST_ID), actualizando interfaz..."

# ── 4.2. Get current interface ───────────────────────────────────────────
  IFACE_ID=$(curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostinterface.get\",\"params\":{\"hostids\":\"$HOST_ID\"},\"id\":6}" \
    | grep -o '"interfaceid":"[^"]*"' | head -1 | cut -d'"' -f4)
    
# ── 4.2.1. Validate IFACE_ID ─────────────────────────────────────────────
if [ -z "$IFACE_ID" ]; then
  echo "❌ No se encontró interfaz para el host $HOST_ID, saliendo..."
  exit 1
fi

# ── 4.3. Update interface to DNS ─────────────────────────────────────────
  curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostinterface.update\",\"params\":{\"interfaceid\":\"$IFACE_ID\",\"type\":1,\"useip\":0,\"dns\":\"$HOST_DNS\",\"ip\":\"\",\"port\":\"$HOST_PORT\",\"main\":1},\"id\":7}" > /dev/null
  echo "   - ✅ Interfaz actualizada a DNS: $HOST_DNS:$HOST_PORT"
else

# ── 4.4. If host does not exist — create it ──────────────────────────────
  echo "➕ Creando host: $HOST_NAME"
  curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"$HOST_NAME\",\"interfaces\":[{\"type\":1,\"main\":1,\"useip\":0,\"ip\":\"\",\"dns\":\"$HOST_DNS\",\"port\":\"$HOST_PORT\"}],\"groups\":[{\"groupid\":\"$GROUP_ID\"}],\"templates\":[{\"templateid\":\"$TEMPLATE_ID\"}]},\"id\":8}" > /dev/null
  echo "✅ Host creado con DNS: $HOST_DNS:$HOST_PORT"
fi

#############################################################################################################
############################    5. CREATE AUTOREGISTRATION ACTION   #########################################
#############################################################################################################

# ── 5.1. Check if action already exists ──────────────────────────────────
ACTION_ID=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"action.get\",\"params\":{\"filter\":{\"name\":[\"Autoregistro-agentes-simovilab\"]},\"output\":[\"actionid\"]},\"id\":1}" \
  | grep -o '"actionid":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ACTION_ID" ]; then
####################
### DOES NOT EXIST ###
####################
  echo "ℹ️  Creando la accion de autoregistro para los agentes remotos"

  # ── 5.2. Get group IDs ───────────────────────────────────────────────────
  GROUP_ADD_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"filter\":{\"name\":[\"$HOST_GROUP\"]},\"output\":[\"groupid\"]},\"id\":1}" \
    | grep -o '"groupid":"[^"]*"' | head -1 | cut -d'"' -f4)

  GROUP_REMOVE_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"filter\":{\"name\":[\"Discovered hosts\"]},\"output\":[\"groupid\"]},\"id\":1}" \
    | grep -o '"groupid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 5.3. Get template IDs ────────────────────────────────────────────────
  TMPL_DOCKER_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"name\":[\"Docker by Zabbix agent 2\"]},\"output\":[\"templateid\"]},\"id\":1}" \
    | grep -o '"templateid":"[^"]*"' | head -1 | cut -d'"' -f4)

  TMPL_LINUX_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"name\":[\"Linux by Zabbix agent active\"]},\"output\":[\"templateid\"]},\"id\":1}" \
    | grep -o '"templateid":"[^"]*"' | head -1 | cut -d'"' -f4)

  echo "   - 📁 Group to add   : $GROUP_ADD_ID"
  echo "   - 📁 Group to remove: $GROUP_REMOVE_ID"
  echo "   - 📋 Docker template: $TMPL_DOCKER_ID"
  echo "   - 📋 Linux template : $TMPL_LINUX_ID"

  # ── 5.4. Create action ───────────────────────────────────────────────────
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"action.create\",\"params\":{\"name\":\"Autoregistro-agentes-simovilab\",\"eventsource\":2,\"status\":0,\"filter\":{\"evaltype\":0,\"conditions\":[{\"conditiontype\":24,\"operator\":2,\"value\":\"docker-autoreg\"}]},\"operations\":[{\"operationtype\":2},{\"operationtype\":4,\"opgroup\":[{\"groupid\":\"$GROUP_ADD_ID\"}]},{\"operationtype\":5,\"opgroup\":[{\"groupid\":\"$GROUP_REMOVE_ID\"}]},{\"operationtype\":6,\"optemplate\":[{\"templateid\":\"$TMPL_DOCKER_ID\"},{\"templateid\":\"$TMPL_LINUX_ID\"}]}]},\"id\":1}" > /dev/null
  echo "   - ✅ Autoregistration action created"
else
################
### EXISTS   ###
################
  echo "   - ℹ️  Action already exists"
fi

#############################################################################################################
###########   6. CREATE NEW USER — only when authenticated with default credentials   #######################
#############################################################################################################

# ── 6.1. Get Super Admin role ID ─────────────────────────────────────────
if [ "$flag_new_user" = "TRUE" ]; then
  echo "ℹ️  Creating new user '$API_WEB_USER' and removing default account"
  echo "🔍 Getting Super Admin role..."
  ROLE_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"role.get","params":{"filter":{"name":["Super admin role"]},"output":["roleid"]},"id":1}' \
    | grep -o '"roleid":"[^"]*"' | head -1 | cut -d'"' -f4)
  
  # ── 6.1.1. Validate ROLE_ID ───────────────────────────────────────────────
  if [ -z "$ROLE_ID" ]; then
    echo "❌ Super Admin role not found, exiting..."
    exit 1
  fi
  echo "   - 👑 Role ID: $ROLE_ID"

  # ── 6.2. Get Zabbix administrators group ID ───────────────────────────────
  echo "🔍 Getting 'Zabbix administrators' group ID..."
  USERGROUP_ID_0=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"usergroup.get","params":{"filter":{"name":["Zabbix administrators"]},"output":["usrgrpid"]},"id":1}' \
    | grep -o '"usrgrpid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 6.2.1. Validate USERGROUP_ID_0 ───────────────────────────────────────
  if [ -z "$USERGROUP_ID_0" ]; then
    echo "❌ Group 'Zabbix administrators' not found, exiting..."
    exit 1
  fi
  echo "   - 👥 'Zabbix administrators' usergroup ID: $USERGROUP_ID_0"

  # ── 6.3. Get Internal group ID ───────────────────────────────────────────
  echo "🔍 Getting 'Internal' group ID..."
  USERGROUP_ID_1=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"usergroup.get","params":{"filter":{"name":["Internal"]},"output":["usrgrpid"]},"id":1}' \
    | grep -o '"usrgrpid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 6.3.1. Validate USERGROUP_ID_1 ───────────────────────────────────────
  if [ -z "$USERGROUP_ID_1" ]; then
    echo "❌ Group 'Internal' not found, exiting..."
    exit 1
  fi
  echo "   - 👥 'Internal' usergroup ID: $USERGROUP_ID_1"

  # ── 6.4. Create new user ──────────────────────────────────────────────────
  # ── 6.4.1. Check if user already exists ──────────────────────────────────
  NEW_USER_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.get\",\"params\":{\"filter\":{\"username\":[\"$API_WEB_USER\"]},\"output\":[\"userid\"]},\"id\":1}" \
    | grep -o '"userid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 6.4.2. If exists — skip creation ─────────────────────────────────────
  if [ -n "$NEW_USER_ID" ]; then
    echo "ℹ️  User '$API_WEB_USER' already exists"
  else
  # ── 6.4.3. If does not exist — create it ─────────────────────────────────
    echo "➕ Creating user: $API_WEB_USER..."
    NEW_USER_ID=$(curl -s -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.create\",\"params\":{\"username\":\"$API_WEB_USER\",\"passwd\":\"$API_WEB_PASS\",\"roleid\":\"$ROLE_ID\",\"usrgrps\":[{\"usrgrpid\":\"$USERGROUP_ID_0\"},{\"usrgrpid\":\"$USERGROUP_ID_1\"}],\"name\":\"$API_WEB_USER\",\"autologin\":0,\"autologout\":\"0\"},\"id\":1}" \
      | grep -o '"userids":\["[^"]*"' | cut -d'"' -f4)

    # ── 6.4.4. Validate NEW_USER_ID ────────────────────────────────────────
    if [ -z "$NEW_USER_ID" ]; then
      echo "❌ Something went wrong creating user $API_WEB_USER, default account will NOT be deleted..."
      echo "🛡️  Verify that the password in .env meets Zabbix security policies:"
      echo "   - 🔐 Password requirements:"
      echo "      - must be at least 8 characters long"
      echo "      - must not contain user's name, surname or username"
      echo "      - must not be one of common or context-specific passwords"
      exit 1
    fi
    echo "   - ✅ User $API_WEB_USER created with ID: $NEW_USER_ID"
  fi

#############################################################################################################
#####################################   7. DELETE DEFAULT ACCOUNT   #########################################
#############################################################################################################

  # ── 7.1. Login with new user ─────────────────────────────────────────────
  echo "   - 🔑 Authenticating with new user..."
  NEW_TOKEN=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$API_WEB_USER\",\"password\":\"$API_WEB_PASS\"},\"id\":1}" \
    | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

  # ── 7.1.1. Validate NEW_TOKEN ────────────────────────────────────────────
  if [ -z "$NEW_TOKEN" ]; then
    echo "⚠️ Could not authenticate with new user, exiting..."
    exit 1
  fi

  echo "   - 🔑 New user token: $NEW_TOKEN"
  echo "ℹ️  Proceeding to delete default account"

  # ── 7.2. Get Admin user ID ───────────────────────────────────────────────
  echo "🔍 Looking up Admin user..."
  ADMIN_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d '{"jsonrpc":"2.0","method":"user.get","params":{"filter":{"username":["Admin"]},"output":["userid"]},"id":1}' \
    | grep -o '"userid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 7.2.1. Validate ADMIN_ID ─────────────────────────────────────────────
  if [ -z "$ADMIN_ID" ]; then
    echo "⚠️ Admin user not found, may have already been deleted, exiting..."
    exit 0
  fi
  echo "   - 🔍 Admin ID: $ADMIN_ID"

  # ── 7.2.2. Transfer maps from Admin to new user ──────────────────────────
  echo "🗺️  Transferring maps from 'Admin' to new user '$API_WEB_USER'..."
  MAPS=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"map.get\",\"params\":{\"filter\":{\"userid\":[\"$ADMIN_ID\"]},\"output\":[\"sysmapid\"]},\"id\":1}" \
    | grep -o '"sysmapid":"[^"]*"' | cut -d'"' -f4)

  for MAP_ID in $MAPS; do
    curl -s -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $NEW_TOKEN" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"map.update\",\"params\":{\"sysmapid\":\"$MAP_ID\",\"userid\":\"$NEW_USER_ID\"},\"id\":1}" > /dev/null
    echo "   - 🗺️  Map '$MAP_ID' transferred"
  done

  # ── 7.2.3. Transfer dashboards from Admin to new user ────────────────────
  echo "📊  Transferring dashboards from Admin to new user '$API_WEB_USER'..."
  DASHBOARDS=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"dashboard.get\",\"params\":{\"filter\":{\"userid\":[\"$ADMIN_ID\"]},\"output\":[\"dashboardid\"]},\"id\":1}" \
    | grep -o '"dashboardid":"[^"]*"' | cut -d'"' -f4)

  for DASH_ID in $DASHBOARDS; do
    curl -s -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $NEW_TOKEN" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"dashboard.update\",\"params\":{\"dashboardid\":\"$DASH_ID\",\"userid\":\"$NEW_USER_ID\"},\"id\":1}" > /dev/null
    echo "   - 📊  Dashboard '$DASH_ID' transferred"
  done

  # ── 7.2.4. Delete Admin user ─────────────────────────────────────────────
  echo "🗑️  Deleting Admin user..."
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.delete\",\"params\":[\"$ADMIN_ID\"],\"id\":1}" > /dev/null

  echo "✅ User 'Admin' deleted"
  echo "✅ User configuration completed"
  echo "   - 👨‍💻 Active user: $API_WEB_USER"
else
  echo "ℹ️  No new user required"
  echo "   - 👨‍💻 Active user: $API_WEB_USER"
fi
  
echo "🎉 Initialization complete"
