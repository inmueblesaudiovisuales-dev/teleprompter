'use strict';
// Servidor local del teleprompter. Corre dentro de la app y no necesita internet:
// la computadora sirve la pantalla, y el teléfono entra por el mismo Wi-Fi a /control.
// Los mensajes viajan así: el teléfono manda órdenes a la pantalla, y la pantalla le
// manda su estado al teléfono. Nunca al revés, así nadie recibe su propio eco.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const QRCode = require('qrcode');

const PUERTO_BASE = 48650;
const MAX_CUERPO = 1024 * 1024;   // el guion más largo cabe de sobra en 1 MB
const MAX_MENSAJE = 8 * 1024;
const TOPICOS = { control: ['cmd', 'hola'], pantalla: ['estado'] };

function esLocal(req) {
  const ip = req.socket.remoteAddress || '';
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

// La dirección de la computadora en el Wi-Fi. Se vuelve a calcular cada vez,
// porque la red puede cambiar con la app abierta.
function ipLocal() {
  const redes = os.networkInterfaces();
  const candidatas = [];
  for (const [nombre, lista] of Object.entries(redes)) {
    for (const r of lista || []) {
      if (r.family !== 'IPv4' && r.family !== 4) continue;
      if (r.internal || r.address.startsWith('169.254.')) continue;
      candidatas.push({ nombre, ip: r.address });
    }
  }
  // en0 es el Wi-Fi en casi todas las Mac; si no está, la primera que sirva.
  const wifi = candidatas.find(c => c.nombre === 'en0');
  return (wifi || candidatas[0] || {}).ip || null;
}

function leerJson(archivo, porDefecto) {
  try { return JSON.parse(fs.readFileSync(archivo, 'utf8')); } catch (_) { return porDefecto; }
}

// Se escribe a un archivo aparte y luego se cambia de nombre: si la app se cierra a
// media escritura, el guion anterior queda entero en vez de un archivo cortado.
function escribirSeguro(archivo, texto) {
  const tmp = archivo + '.tmp';
  fs.writeFileSync(tmp, texto);
  fs.renameSync(tmp, archivo);
}

function leerCuerpo(req, max) {
  return new Promise((ok, falla) => {
    let n = 0;
    const partes = [];
    req.on('data', d => {
      n += d.length;
      if (n > max) { falla(Object.assign(new Error('grande'), { codigo: 413 })); req.destroy(); return; }
      partes.push(d);
    });
    req.on('end', () => ok(Buffer.concat(partes).toString('utf8')));
    req.on('error', falla);
  });
}

function responder(res, codigo, cuerpo, tipo = 'application/json; charset=utf-8') {
  res.writeHead(codigo, { 'Content-Type': tipo, 'Cache-Control': 'no-store' });
  res.end(typeof cuerpo === 'string' || Buffer.isBuffer(cuerpo) ? cuerpo : JSON.stringify(cuerpo));
}

async function crear({ carpetaDatos, pagina, puerto = PUERTO_BASE }) {
  fs.mkdirSync(carpetaDatos, { recursive: true });
  const archivoAjustes = path.join(carpetaDatos, 'ajustes.json');
  const archivoClave = path.join(carpetaDatos, 'clave.txt');

  // La clave va en el QR. Sin ella, alguien más en el mismo Wi-Fi no puede controlar.
  let clave = '';
  try { clave = fs.readFileSync(archivoClave, 'utf8').trim(); } catch (_) {}
  if (!/^[a-f0-9]{24}$/.test(clave)) {
    clave = crypto.randomBytes(12).toString('hex');
    escribirSeguro(archivoClave, clave);
  }

  const clientes = new Set();   // { res, rol }

  function mandar(rolDestino, topic, data) {
    const linea = `data: ${JSON.stringify({ topic, data })}\n\n`;
    for (const c of clientes) if (c.rol === rolDestino) { try { c.res.write(linea); } catch (_) {} }
  }
  function avisarTelefonos() {
    let n = 0;
    for (const c of clientes) if (c.rol === 'control') n++;
    mandar('pantalla', 'telefonos', n);
  }

  // Un renglón vacío cada 15 s para que ni el teléfono ni el Wi-Fi corten la conexión callada.
  const latido = setInterval(() => {
    for (const c of clientes) { try { c.res.write(': latido\n\n'); } catch (_) {} }
  }, 15000);

  const servidor = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      const ruta = url.pathname;
      const local = esLocal(req);
      const conClave = url.searchParams.get('k') === clave;

      if (req.method === 'GET' && (ruta === '/' || ruta === '/control')) {
        // La pantalla solo se abre en esta computadora; el teléfono solo entra al control con su clave.
        if (ruta === '/' && !local) return responder(res, 403, 'Esta página solo abre en la computadora.', 'text/plain; charset=utf-8');
        if (ruta === '/control' && !conClave) return responder(res, 403, 'Vuelve a escanear el código de la computadora.', 'text/plain; charset=utf-8');
        return responder(res, 200, fs.readFileSync(pagina), 'text/html; charset=utf-8');
      }

      if (ruta === '/api/ajustes') {
        if (!local) return responder(res, 403, { error: 'solo local' });
        if (req.method === 'GET') return responder(res, 200, leerJson(archivoAjustes, {}));
        if (req.method === 'POST') {
          const cuerpo = await leerCuerpo(req, MAX_CUERPO);
          let datos;
          try { datos = JSON.parse(cuerpo); } catch (_) { return responder(res, 400, { error: 'no es JSON' }); }
          if (!datos || typeof datos !== 'object' || Array.isArray(datos)) return responder(res, 400, { error: 'forma' });
          escribirSeguro(archivoAjustes, JSON.stringify(datos));
          return responder(res, 200, { ok: true });
        }
      }

      // El teléfono lee el guion para elegir desde qué palabra empezar. Solo el texto:
      // los demás ajustes (la raya, el tamaño) son de la computadora.
      if (req.method === 'GET' && ruta === '/api/guion') {
        if (!local && !conClave) return responder(res, 403, { error: 'clave' });
        const a = leerJson(archivoAjustes, {});
        return responder(res, 200, { texto: a && typeof a.texto === 'string' ? a.texto : '' });
      }

      if (req.method === 'GET' && ruta === '/api/qr') {
        if (!local) return responder(res, 403, { error: 'solo local' });
        const ip = ipLocal();
        if (!ip) return responder(res, 200, { error: 'sin-red' });
        const liga = `http://${ip}:${servidor.address().port}/control?k=${clave}`;
        const imagen = await QRCode.toDataURL(liga, { margin: 1, width: 440, errorCorrectionLevel: 'M' });
        return responder(res, 200, { liga, imagen });
      }

      if (req.method === 'GET' && ruta === '/api/eventos') {
        const rol = url.searchParams.get('rol');
        if (rol === 'pantalla' && !local) return responder(res, 403, { error: 'solo local' });
        if (rol === 'control' && !conClave) return responder(res, 403, { error: 'clave' });
        if (rol !== 'pantalla' && rol !== 'control') return responder(res, 400, { error: 'rol' });
        res.writeHead(200, {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-store',
          Connection: 'keep-alive',
        });
        res.write('retry: 1500\n\n');
        const c = { res, rol };
        clientes.add(c);
        avisarTelefonos();
        req.on('close', () => { clientes.delete(c); avisarTelefonos(); });
        return;
      }

      if (req.method === 'POST' && ruta === '/api/enviar') {
        const rol = url.searchParams.get('rol');
        if (rol === 'pantalla' && !local) return responder(res, 403, { error: 'solo local' });
        if (rol === 'control' && !conClave) return responder(res, 403, { error: 'clave' });
        if (!TOPICOS[rol]) return responder(res, 400, { error: 'rol' });
        let m;
        try { m = JSON.parse(await leerCuerpo(req, MAX_MENSAJE)); } catch (e) {
          return responder(res, e.codigo || 400, { error: 'mensaje' });
        }
        if (!m || !TOPICOS[rol].includes(m.topic)) return responder(res, 400, { error: 'tema' });
        mandar(rol === 'control' ? 'pantalla' : 'control', m.topic, m.data === undefined ? null : m.data);
        return responder(res, 200, { ok: true });
      }

      responder(res, 404, { error: 'no existe' });
    } catch (e) {
      if (!res.headersSent) responder(res, e.codigo || 500, { error: 'falla' });
      else try { res.end(); } catch (_) {}
    }
  });

  // Si el puerto está ocupado, se prueban los diez siguientes. La clave no cambia,
  // pero el QR sí; por eso siempre se pide de nuevo al abrirlo.
  const puertoFinal = await new Promise((ok, falla) => {
    let p = puerto;
    const intentar = () => {
      servidor.once('error', e => {
        if (e.code === 'EADDRINUSE' && p < puerto + 10) { p++; intentar(); } else falla(e);
      });
      servidor.listen(p, '0.0.0.0', () => ok(p));
    };
    intentar();
  });

  return {
    puerto: puertoFinal,
    clave,
    urlLocal: `http://127.0.0.1:${puertoFinal}/`,
    cerrar: () => new Promise(ok => {
      clearInterval(latido);
      for (const c of clientes) { try { c.res.end(); } catch (_) {} }
      servidor.close(() => ok());
      // Sin esto, close() espera a que el teléfono suelte su conexión y la app no termina de cerrar.
      try { servidor.closeAllConnections(); } catch (_) {}
    }),
  };
}

module.exports = { crear, ipLocal };

// Para probar sin la app: node servidor.js
if (require.main === module) {
  crear({ carpetaDatos: path.join(__dirname, '.datos-prueba'), pagina: path.join(__dirname, 'pantalla.html') })
    .then(s => console.log('listo', s.urlLocal));
}
