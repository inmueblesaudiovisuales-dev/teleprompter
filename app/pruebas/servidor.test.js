'use strict';
// Pruebas del servidor local: se le habla de verdad por la red, como lo harían la
// pantalla y el teléfono. Las que dicen "desde el Wi-Fi" entran por la dirección de
// la red y no por la de la propia computadora, que es justo lo que hace el teléfono.

const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { crear, ipLocal } = require('./arrancar');

const PAGINA = path.join(__dirname, '..', 'pantalla.html');
const carpeta = () => fs.mkdtempSync(path.join(os.tmpdir(), 'tp-'));

function pedir(host, puerto, metodo, ruta, cuerpo, tipo = 'application/json') {
  return new Promise((ok, falla) => {
    const req = http.request({ agent: false, host, port: puerto, method: metodo, path: ruta, headers: cuerpo ? { 'Content-Type': tipo } : {} }, res => {
      const partes = [];
      res.on('data', d => partes.push(d));
      res.on('end', () => {
        const texto = Buffer.concat(partes).toString('utf8');
        let json = null;
        try { json = JSON.parse(texto); } catch (_) {}
        ok({ estado: res.statusCode, texto, json, tipo: res.headers['content-type'] });
      });
    });
    req.on('error', falla);
    if (cuerpo) req.write(cuerpo);
    req.end();
  });
}

// Un oyente de eventos como el de la página: junta lo que le llega.
function escuchar(host, puerto, ruta) {
  return new Promise((ok, falla) => {
    const recibidos = [];
    const req = http.get({ agent: false, host, port: puerto, path: ruta }, res => {
      if (res.statusCode !== 200) { res.resume(); ok({ estado: res.statusCode, recibidos, cerrar() {} }); return; }
      let resto = '';
      res.on('data', d => {
        resto += d.toString('utf8');
        let i;
        while ((i = resto.indexOf('\n\n')) >= 0) {
          const bloque = resto.slice(0, i); resto = resto.slice(i + 2);
          const linea = bloque.split('\n').find(l => l.startsWith('data: '));
          if (linea) recibidos.push(JSON.parse(linea.slice(6)));
        }
      });
      ok({ estado: 200, recibidos, cerrar: () => req.destroy() });
    });
    req.on('error', falla);
  });
}
const esperar = ms => new Promise(r => setTimeout(r, ms));

test('servidor local', async t => {
  const datos = carpeta();
  const s = await crear({ carpetaDatos: datos, pagina: PAGINA, puerto: 48750 });
  const L = '127.0.0.1', P = s.puerto, K = s.clave;
  const wifi = ipLocal();
  t.after(() => s.cerrar());

  await t.test('la pantalla abre en la computadora', async () => {
    const r = await pedir(L, P, 'GET', '/');
    assert.strictEqual(r.estado, 200);
    assert.match(r.tipo, /text\/html/);
    assert.match(r.texto, /<title>Teleprompter/);
  });

  await t.test('el control pide la clave', async () => {
    assert.strictEqual((await pedir(L, P, 'GET', '/control')).estado, 403);
    assert.strictEqual((await pedir(L, P, 'GET', '/control?k=equivocada')).estado, 403);
    assert.strictEqual((await pedir(L, P, 'GET', '/control?k=' + K)).estado, 200);
  });

  await t.test('lo que no existe contesta 404', async () => {
    assert.strictEqual((await pedir(L, P, 'GET', '/otra')).estado, 404);
  });

  await t.test('guarda y devuelve el guion', async () => {
    assert.deepStrictEqual((await pedir(L, P, 'GET', '/api/ajustes')).json, {});
    const cfg = { texto: 'Hola [PAUSA]\n\nsegundo ñandú 🎬', velocidad: 7 };
    assert.strictEqual((await pedir(L, P, 'POST', '/api/ajustes', JSON.stringify(cfg))).estado, 200);
    assert.deepStrictEqual((await pedir(L, P, 'GET', '/api/ajustes')).json, cfg);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(datos, 'ajustes.json'), 'utf8')), cfg);
  });

  await t.test('rechaza lo que no es un guion, sin perder el anterior', async () => {
    assert.strictEqual((await pedir(L, P, 'POST', '/api/ajustes', '{roto')).estado, 400);
    assert.strictEqual((await pedir(L, P, 'POST', '/api/ajustes', '[1,2]')).estado, 400);
    assert.strictEqual((await pedir(L, P, 'POST', '/api/ajustes', 'null')).estado, 400);
    const grande = JSON.stringify({ texto: 'x'.repeat(1100 * 1024) });
    const r = await pedir(L, P, 'POST', '/api/ajustes', grande).catch(() => ({ estado: 413 }));
    assert.strictEqual(r.estado, 413);
    assert.strictEqual((await pedir(L, P, 'GET', '/api/ajustes')).json.velocidad, 7);
  });

  await t.test('un guion largo (cien mil palabras) sí cabe', async () => {
    const largo = { texto: 'palabra '.repeat(100000) };
    assert.strictEqual((await pedir(L, P, 'POST', '/api/ajustes', JSON.stringify(largo))).estado, 200);
    assert.strictEqual((await pedir(L, P, 'GET', '/api/ajustes')).json.texto.length, largo.texto.length);
  });

  await t.test('el teléfono lee el guion con su clave, y solo el texto', async () => {
    await pedir(L, P, 'POST', '/api/ajustes', JSON.stringify({ texto: 'Uno dos [nota] tres', raya: { activa: true }, velocidad: 7 }));
    assert.strictEqual((await pedir(L, P, 'GET', '/api/guion?k=mal')).estado, 200, 'desde la propia computadora sí');
    const r = await pedir(L, P, 'GET', '/api/guion?k=' + K);
    assert.deepStrictEqual(r.json, { texto: 'Uno dos [nota] tres' });
    if (wifi) {
      assert.strictEqual((await pedir(wifi, P, 'GET', '/api/guion')).estado, 403, 'sin clave, desde el Wi-Fi, no');
      assert.deepStrictEqual((await pedir(wifi, P, 'GET', '/api/guion?k=' + K)).json, { texto: 'Uno dos [nota] tres' });
    }
  });

  await t.test('el QR trae la liga del Wi-Fi con la clave', async () => {
    const r = await pedir(L, P, 'GET', '/api/qr');
    assert.strictEqual(r.estado, 200);
    if (!wifi) { assert.strictEqual(r.json.error, 'sin-red'); return; }
    assert.strictEqual(r.json.liga, `http://${wifi}:${P}/control?k=${K}`);
    assert.match(r.json.imagen, /^data:image\/png;base64,/);
  });

  await t.test('el teléfono manda órdenes y la pantalla las recibe', async () => {
    const pantalla = await escuchar(L, P, '/api/eventos?rol=pantalla');
    const tel = await escuchar(L, P, `/api/eventos?rol=control&k=${K}`);
    await esperar(100);
    assert.deepStrictEqual(pantalla.recibidos.at(-1), { topic: 'telefonos', data: 1 });
    assert.strictEqual((await pedir(L, P, 'POST', `/api/enviar?rol=control&k=${K}`, JSON.stringify({ topic: 'cmd', data: { a: 'alternar' } }))).estado, 200);
    assert.strictEqual((await pedir(L, P, 'POST', '/api/enviar?rol=pantalla', JSON.stringify({ topic: 'estado', data: { corriendo: true } }))).estado, 200);
    await esperar(100);
    assert.ok(pantalla.recibidos.some(m => m.topic === 'cmd' && m.data.a === 'alternar'));
    assert.ok(tel.recibidos.some(m => m.topic === 'estado' && m.data.corriendo === true));
    // Nadie recibe su propio eco ni lo que no le toca.
    assert.ok(!tel.recibidos.some(m => m.topic === 'cmd'));
    assert.ok(!pantalla.recibidos.some(m => m.topic === 'estado'));
    tel.cerrar();
    await esperar(150);
    assert.deepStrictEqual(pantalla.recibidos.at(-1), { topic: 'telefonos', data: 0 });
    pantalla.cerrar();
  });

  await t.test('dos teléfonos se cuentan bien', async () => {
    const pantalla = await escuchar(L, P, '/api/eventos?rol=pantalla');
    const t1 = await escuchar(L, P, `/api/eventos?rol=control&k=${K}`);
    const t2 = await escuchar(L, P, `/api/eventos?rol=control&k=${K}`);
    await esperar(100);
    assert.strictEqual(pantalla.recibidos.at(-1).data, 2);
    t1.cerrar(); await esperar(150);
    assert.strictEqual(pantalla.recibidos.at(-1).data, 1);
    t2.cerrar(); pantalla.cerrar();
  });

  await t.test('mensajes que no se aceptan', async () => {
    const e = (q, b) => pedir(L, P, 'POST', '/api/enviar?' + q, b);
    assert.strictEqual((await e(`rol=control&k=mal`, JSON.stringify({ topic: 'cmd' }))).estado, 403);
    assert.strictEqual((await e(`rol=control&k=${K}`, JSON.stringify({ topic: 'estado' }))).estado, 400, 'el teléfono no manda estado');
    assert.strictEqual((await e(`rol=pantalla`, JSON.stringify({ topic: 'cmd' }))).estado, 400, 'la pantalla no manda órdenes');
    assert.strictEqual((await e(`rol=otro`, JSON.stringify({ topic: 'cmd' }))).estado, 400);
    assert.strictEqual((await e(`rol=control&k=${K}`, 'no json')).estado, 400);
    const r = await e(`rol=control&k=${K}`, JSON.stringify({ topic: 'cmd', data: 'x'.repeat(9000) })).catch(() => ({ estado: 413 }));
    assert.strictEqual(r.estado, 413);
  });

  await t.test('desde el Wi-Fi: sin clave no se entra a nada', { skip: !wifi && 'sin Wi-Fi' }, async () => {
    assert.strictEqual((await pedir(wifi, P, 'GET', '/')).estado, 403, 'la pantalla no se abre desde otro aparato');
    assert.strictEqual((await pedir(wifi, P, 'GET', '/api/ajustes')).estado, 403, 'nadie lee el guion');
    assert.strictEqual((await pedir(wifi, P, 'POST', '/api/ajustes', '{}')).estado, 403, 'nadie borra el guion');
    assert.strictEqual((await pedir(wifi, P, 'GET', '/api/qr')).estado, 403);
    assert.strictEqual((await escuchar(wifi, P, '/api/eventos?rol=pantalla')).estado, 403, 'nadie se hace pasar por la pantalla');
    assert.strictEqual((await pedir(wifi, P, 'POST', '/api/enviar?rol=pantalla', JSON.stringify({ topic: 'estado' }))).estado, 403);
    assert.strictEqual((await pedir(wifi, P, 'GET', '/control')).estado, 403);
  });

  await t.test('desde el Wi-Fi: con la clave, el control funciona', { skip: !wifi && 'sin Wi-Fi' }, async () => {
    assert.strictEqual((await pedir(wifi, P, 'GET', '/control?k=' + K)).estado, 200);
    const pantalla = await escuchar(L, P, '/api/eventos?rol=pantalla');
    const tel = await escuchar(wifi, P, `/api/eventos?rol=control&k=${K}`);
    assert.strictEqual(tel.estado, 200);
    await pedir(wifi, P, 'POST', `/api/enviar?rol=control&k=${K}`, JSON.stringify({ topic: 'cmd', data: { a: 'vel+' } }));
    await esperar(100);
    assert.ok(pantalla.recibidos.some(m => m.topic === 'cmd' && m.data.a === 'vel+'));
    tel.cerrar(); pantalla.cerrar();
  });
});

test('la clave y el guion sobreviven a cerrar y abrir la app', async () => {
  const datos = carpeta();
  const a = await crear({ carpetaDatos: datos, pagina: PAGINA, puerto: 48770 });
  await pedir('127.0.0.1', a.puerto, 'POST', '/api/ajustes', JSON.stringify({ texto: 'guardado' }));
  const clave = a.clave;
  await a.cerrar();
  const b = await crear({ carpetaDatos: datos, pagina: PAGINA, puerto: 48770 });
  try {
    assert.strictEqual(b.clave, clave);
    assert.strictEqual((await pedir('127.0.0.1', b.puerto, 'GET', '/api/ajustes')).json.texto, 'guardado');
  } catch (e) { console.log('DETALLE', e.message); throw e; } finally { await b.cerrar(); }
});

test('un archivo de guion dañado no impide abrir', async () => {
  const datos = carpeta();
  fs.writeFileSync(path.join(datos, 'ajustes.json'), '{medio archivo');
  fs.writeFileSync(path.join(datos, 'clave.txt'), 'basura');
  const s = await crear({ carpetaDatos: datos, pagina: PAGINA, puerto: 48780 });
  assert.deepStrictEqual((await pedir('127.0.0.1', s.puerto, 'GET', '/api/ajustes')).json, {});
  assert.match(s.clave, /^[a-f0-9]{24}$/);
  await s.cerrar();
});

test('si el puerto está ocupado, usa el siguiente', async () => {
  const ocupa = http.createServer().listen(48790, '0.0.0.0');
  await new Promise(r => ocupa.once('listening', r));
  const s = await crear({ carpetaDatos: carpeta(), pagina: PAGINA, puerto: 48790 });
  assert.strictEqual(s.puerto, 48791);
  assert.strictEqual((await pedir('127.0.0.1', s.puerto, 'GET', '/')).estado, 200);
  await s.cerrar();
  ocupa.close();
});
