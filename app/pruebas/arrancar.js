'use strict';
// Las pruebas del servidor corren contra cualquiera de las dos versiones:
//   - por defecto, el servidor de la versión anterior (servidor.js);
//   - con TP_SWIFT=<ruta al programa>, el de la app en Swift, corriendo de verdad.
// Así se comprueba que la versión nueva contesta exactamente igual que la anterior.

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const node = require('../servidor');

async function crearSwift({ carpetaDatos, pagina, puerto }) {
  const proc = spawn(process.env.TP_SWIFT, ['--solo-servidor', '--datos', carpetaDatos, '--puerto', String(puerto), '--pagina', pagina]);
  const p = await new Promise((ok, falla) => {
    let salida = '';
    const t = setTimeout(() => falla(new Error('el servidor no arrancó: ' + salida)), 5000);
    proc.stdout.on('data', d => {
      salida += d;
      const m = salida.match(/listo (\d+)/);
      if (m) { clearTimeout(t); ok(Number(m[1])); }
    });
    proc.stderr.on('data', d => { salida += d; });
    proc.on('exit', c => { clearTimeout(t); falla(new Error('el servidor se cerró (' + c + '): ' + salida)); });
  });
  return {
    puerto: p,
    clave: fs.readFileSync(path.join(carpetaDatos, 'clave.txt'), 'utf8').trim(),
    urlLocal: `http://127.0.0.1:${p}/`,
    cerrar: () => new Promise(ok => { proc.once('exit', () => ok()); proc.kill('SIGTERM'); }),
  };
}

module.exports = {
  crear: process.env.TP_SWIFT ? crearSwift : node.crear,
  ipLocal: node.ipLocal,
};
