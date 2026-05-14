#!/usr/bin/env bash
########################################################################################################################
###### Script de instalacion de Zabbix, es ejecutado por el servicio zabbix-init, definido en docker-compose.yml #######
########################################################################################################################

#──── Si hay error sale del script, e=exit on error, u=exit on undefined var ──────────
set -eu
#──── Para saber si se debe crear un nuevo usuario con los datos API_WEB_USER y API_WEB_PASS de .env *** NO CAMBIAR EL VALOR *** ──────────
flag_new_user=FALSE           

#############################################################################################################
#######################################    0. API DISPONIBLE?   #############################################
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
##########################################    1. Autenticar   ###############################################
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
echo "   - 🔑 Token obtenido correctamente"

#############################################################################################################
###############################    2. Obtener o crear Host Group    #########################################
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
#####################################    3. Obtener Template ID   ###########################################
#############################################################################################################

TEMPLATE_ID=$(curl -sf -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"host\":[\"$HOST_TEMPLATE\"]}},\"id\":4}" \
  | grep -o '"templateid":"[^"]*"' | head -1 | cut -d'"' -f4)

# ── 3.1. Validación del TEMPLATE_ID ─────────────────────────────────
if [ -z "$TEMPLATE_ID" ]; then
  echo "❌ Template '$HOST_TEMPLATE' no encontrado, saliendo..."
  exit 1
fi

echo "📋 '$HOST_TEMPLATE' template ID: $TEMPLATE_ID"

#############################################################################################################
#############################    4. Verificar si el host ya existe   ########################################
#############################################################################################################

HOST_ID=$(curl -sf -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$HOST_NAME\"]}},\"id\":5}" \
  | grep -o '"hostid":"[^"]*"' | head -1 | cut -d'"' -f4)

# ── 4.1.1 Si existe se actualiza interfaz ──────────────────────────────
if [ -n "$HOST_ID" ]; then
  echo "🔄 Host ya existe (ID: $HOST_ID), actualizando interfaz..."

# ── 4.2. Obtener interfaz actual ───────────────────────────────────────
  IFACE_ID=$(curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostinterface.get\",\"params\":{\"hostids\":\"$HOST_ID\"},\"id\":6}" \
    | grep -o '"interfaceid":"[^"]*"' | head -1 | cut -d'"' -f4)
    
# ── 4.1.1. Validación del IFACE_ID ──────────────────────────────────────
if [ -z "$IFACE_ID" ]; then
  echo "❌ No se encontró interfaz para el host $HOST_ID, saliendo..."
  exit 1
fi

# ── 4.2. Actualizar interfaz a DNS ──────────────────────────────────────
  curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostinterface.update\",\"params\":{\"interfaceid\":\"$IFACE_ID\",\"type\":1,\"useip\":0,\"dns\":\"$HOST_DNS\",\"ip\":\"\",\"port\":\"$HOST_PORT\",\"main\":1},\"id\":7}" > /dev/null
  echo "   - ✅ Interfaz actualizada a DNS: $HOST_DNS:$HOST_PORT"
else

# ── 4.2.1. Si no existe se crea ────────────────────
  echo "➕ Creando host: $HOST_NAME"
  curl -sf -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"$HOST_NAME\",\"interfaces\":[{\"type\":1,\"main\":1,\"useip\":0,\"ip\":\"\",\"dns\":\"$HOST_DNS\",\"port\":\"$HOST_PORT\"}],\"groups\":[{\"groupid\":\"$GROUP_ID\"}],\"templates\":[{\"templateid\":\"$TEMPLATE_ID\"}]},\"id\":8}"
  echo "✅ Host creado con DNS: $HOST_DNS:$HOST_PORT"
fi
  echo "ℹ️  Creando la accion de autoregistro para los agentes remotos"

#############################################################################################################
############################    5. Creando la acción de auto registro   #####################################
#############################################################################################################

# ── 5.1. Verificar si la action ya existe ─────────────────────────────────────────

ACTION_ID=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"action.get\",\"params\":{\"filter\":{\"name\":[\"Autoregistro-agentes-simovilab\"]},\"output\":[\"actionid\"]},\"id\":1}" \
  | grep -o '"actionid":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ACTION_ID" ]; then
#################
### NO EXISTE ###
#################
  # ── 5.2. Obtener los ID de los Grupos ─────────────────────────────────────────

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

  # ── 5.3. Obtener los ID de los Templates ─────────────────────────────────────────

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

  echo "   - 📁 Grupo a agregar : $GROUP_ADD_ID"
  echo "   - 📁 Grupo a remover : $GROUP_REMOVE_ID"
  echo "   - 📋 Template Docker: $TMPL_DOCKER_ID"
  echo "   - 📋 Template Linux : $TMPL_LINUX_ID"

  # ── 5.4. Crear Action ───────────────────────────────────────────

  curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"action.create\",\"params\":{\"name\":\"Autoregistro-agentes-simovilab\",\"eventsource\":2,\"status\":0,\"filter\":{\"evaltype\":0,\"conditions\":[{\"conditiontype\":24,\"operator\":2,\"value\":\"docker-autoreg\"}]},\"operations\":[{\"operationtype\":2},{\"operationtype\":4,\"opgroup\":[{\"groupid\":\"$GROUP_ADD_ID\"}]},{\"operationtype\":5,\"opgroup\":[{\"groupid\":\"$GROUP_REMOVE_ID\"}]},{\"operationtype\":6,\"optemplate\":[{\"templateid\":\"$TMPL_DOCKER_ID\"},{\"templateid\":\"$TMPL_LINUX_ID\"}]}]},\"id\":1}" > /dev/null
  echo ""
  echo "   - ✅ Accion de autoregistro creada"
else
#################
### SI EXISTE ###
#################
  echo "   - ℹ️  La accion ya existe"
fi

#############################################################################################################
###########   6. Creando nuevo usuario, solo cuando se logea con creedenciales "default"  ###################
#############################################################################################################

# ── 6.1. Obtener ID del role Super Admin ─────────────────
if [ "$flag_new_user" = "TRUE" ]; then
  echo "ℹ️  Creando el nuevo usuario '$API_WEB_USER' y eliminando la cuenta por defecto"
  echo "🔍 Obteniendo rol Super Admin..."
  ROLE_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"role.get","params":{"filter":{"name":["Super admin role"]},"output":["roleid"]},"id":1}' \
    | grep -o '"roleid":"[^"]*"' | head -1 | cut -d'"' -f4)
  
  # ── 6.1.1. Validación del ROLE_ID ─────────────────────────────────
  if [ -z "$ROLE_ID" ]; then
    echo "❌ Role Super Admin no encontrado, saliendo..."
    exit 1
  fi
  echo "   - 👑 Role ID: $ROLE_ID"

  # ── 6.2. Obtener ID del grupo Zabbix administrators ─────────────────
  echo "🔍 Obteniendo ID del grupo 'Zabbix administrators'..."
  USERGROUP_ID_0=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"usergroup.get","params":{"filter":{"name":["Zabbix administrators"]},"output":["usrgrpid"]},"id":1}' \
    | grep -o '"usrgrpid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 6.2.1. Validación del USERGROUP_ID_0 ─────────────────────────────────
  if [ -z "$USERGROUP_ID_0" ]; then
    echo "❌ Grupo 'Zabbix administrators' no encontrado, saliendo..."
    exit 1
  fi
  echo "   - 👥 'Zabbix administrators' usergroup ID: $USERGROUP_ID_0"

  # ── 6.3. Obtener ID del grupo Internal ─────────────────
  echo "🔍 Obteniendo ID del grupo 'Internal'..."
  USERGROUP_ID_1=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","method":"usergroup.get","params":{"filter":{"name":["Internal"]},"output":["usrgrpid"]},"id":1}' \
    | grep -o '"usrgrpid":"[^"]*"' | head -1 | cut -d'"' -f4)
  # ── 6.3.1. Validación del USERGROUP_ID_1 ─────────────────────────────────
  if [ -z "$USERGROUP_ID_1" ]; then
    echo "❌ Grupo 'Internal' no encontrado, saliendo..."
    exit 1
  fi
  echo "   - 👥 'Internal' usergroup ID: $USERGROUP_ID_1"

  # ── 6.4. Crear nuevo usuario ─────────────────────────────────
  # ── 6.4.1. Verificar si el usuario ya existe ─────────────────────────────────
  NEW_USER_ID=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.get\",\"params\":{\"filter\":{\"username\":[\"$API_WEB_USER\"]},\"output\":[\"userid\"]},\"id\":1}" \
  | grep -o '"userid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 6.4.2. Si existe no se hace nada ────────────────────
  if [ -n "$NEW_USER_ID" ]; then
    echo "ℹ️  El usuario '$API_WEB_USER' ya existe"
  else
  # ── 6.4.3. Si no existe se crea ────────────────────
  echo "➕ Creando usuario: $API_WEB_USER..."
  NEW_USER_ID=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.create\",\"params\":{\"username\":\"$API_WEB_USER\",\"passwd\":\"$API_WEB_PASS\",\"roleid\":\"$ROLE_ID\",\"usrgrps\":[{\"usrgrpid\":\"$USERGROUP_ID_0\"},{\"usrgrpid\":\"$USERGROUP_ID_1\"}],\"name\":\"$API_WEB_USER\",\"autologin\":0,\"autologout\":\"0\"},\"id\":1}" \
  | grep -o '"userids":\["[^"]*"' | cut -d'"' -f4)

  # ── 6.4.4. Validación del NEW_USER_ID ─────────────────────────────────
  if [ -z "$NEW_USER_ID" ]; then
    echo "❌  Error: algo salió mal al crear el usuario $API_WEB_USER, en consecuencia no se borrará la cuenta por defecto..."
    echo "🛡️  Verifique que la contraseña en .env cumpla con las politicas de seguridad establecidas por Zabbix:"
    echo "   - 🔐 Password requirements:"
    echo "      - must be at least 8 characters long"
    echo "      - must not contain user's name, surname or username"
    echo "      - must not be one of common or context-specific passwords"
    echo "🎉 Inicialización completa"
    exit 1
  fi
  echo "   - ✅ Usuario $API_WEB_USER creado con ID: $NEW_USER_ID"
  fi

#############################################################################################################
#####################################   7. Eliminando la cuenta por defecto #################################
#############################################################################################################

  # ── 7.1. Login con el nuevo usuario ─────────────────────────
  echo "   - 🔑 Autenticando con nuevo usuario..."
  NEW_TOKEN=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$API_WEB_USER\",\"password\":\"$API_WEB_PASS\"},\"id\":1}" \
    | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

  # ── 7.1.1. Validación del NEW_TOKEN  ─────────────────────────────────
  if [ -z "$NEW_TOKEN" ]; then
    echo "⚠️ No se pudo autenticar con el nuevo usuario, saliendo..."
    exit 1
  fi

  echo "   - 🔑 Token para el nuevo usuario obtenido correctamente"
  echo "ℹ️  Se procede a eliminar la cuenta por defecto"

  # ── 7.2. Obtener ID del usuario Admin ───────────────────────
  echo "🔍 Buscando usuario Admin..."
  ADMIN_ID=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d '{"jsonrpc":"2.0","method":"user.get","params":{"filter":{"username":["Admin"]},"output":["userid"]},"id":1}' \
    | grep -o '"userid":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── 7.2.1. Validación del ADMIN_ID  ─────────────────────────────────
  if [ -z "$ADMIN_ID" ]; then
    echo "⚠️ Usuario Admin no encontrado, puede ser que ya ha sido eliminado, saliendo..."
    exit 0
  fi
  echo "   - 🔍 Admin ID: $ADMIN_ID"

  # ── 7.2.2 Transferir mapas de Admin al nuevo usuario ──────
  echo "🗺️  Transfiriendo mapas de 'Admin' al nuevo usuario '$API_WEB_USER'..."
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
    echo "   - 🗺️  Mapa '$MAP_ID' transferido"
  done

  # ── 7.2.3 Transferir dashboards de Admin al nuevo usuario ──
  echo "📊  Transfiriendo dashboards de Admin al nuevo usuario '$API_WEB_USER'..."
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
    echo "   - 📊  Dashboard '$DASH_ID' transferido"
  done
  
  # ── 7.2.4 Eliminar usuario Admin ──────────────────────────────
  echo "🗑️  Eliminando usuario Admin..."
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NEW_TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.delete\",\"params\":[\"$ADMIN_ID\"],\"id\":1}" > /dev/null

  echo "✅ Usuario 'Admin' eliminado"
  echo "✅ Configuración de usuarios completada"
  echo "   - 👨‍💻 Usuario activo: $API_WEB_USER"
else
  echo "ℹ️  No se requiere crear un nuevo usuario"
  echo "   - 👨‍💻 Usuario activo: $API_WEB_USER"
fi
  
echo "🎉 Inicialización completa"
