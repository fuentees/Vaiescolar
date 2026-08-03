// Mantem, em memoria, quais conexoes de pais estao inscritas em cada viagem.
// tripId -> Set<WebSocket>
const rooms = new Map();

function subscribe(tripId, ws) {
  if (!rooms.has(tripId)) rooms.set(tripId, new Set());
  rooms.get(tripId).add(ws);
  ws.on('close', () => {
    const set = rooms.get(tripId);
    if (set) {
      set.delete(ws);
      if (set.size === 0) rooms.delete(tripId);
    }
  });
}

// Envia a nova posicao apenas para os pais inscritos NAQUELA viagem.
function broadcast(tripId, payload) {
  const set = rooms.get(tripId);
  if (!set) return;
  const msg = JSON.stringify(payload);
  for (const ws of set) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

module.exports = { subscribe, broadcast };
