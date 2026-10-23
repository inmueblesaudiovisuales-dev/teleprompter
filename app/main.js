'use strict';
// La app de escritorio: abre una ventana con el teleprompter y prende el servidor
// local para que el teléfono lo controle por el Wi-Fi. No usa internet para nada.

const { app, BrowserWindow, shell, dialog } = require('electron');
const path = require('path');
const { crear } = require('./servidor');

// Una sola copia abierta: una segunda pelearía por el puerto y por el archivo del guion.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let ventana = null;
  let servidor = null;
  let cerrando = false;

  app.on('second-instance', () => {
    if (ventana) { if (ventana.isMinimized()) ventana.restore(); ventana.focus(); }
  });

  app.whenReady().then(async () => {
    try {
      servidor = await crear({
        carpetaDatos: app.getPath('userData'),
        pagina: path.join(__dirname, 'pantalla.html'),
      });
    } catch (e) {
      dialog.showErrorBox('No se pudo abrir el teleprompter', 'Otro programa está usando la conexión que necesita. Cierra otras copias de la app y vuelve a abrirla.');
      app.quit();
      return;
    }

    ventana = new BrowserWindow({
      width: 1100,
      height: 760,
      minWidth: 420,
      minHeight: 360,
      backgroundColor: '#0d0f12',
      title: 'Teleprompter',
      // backgroundThrottling apagado: si la ventana queda detrás de otra, el texto no se frena.
      webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false },
    });
    ventana.setMenuBarVisibility(false);
    // El monitor donde se usa tiene una raya justo a la mitad, y la pantalla deja libre la
    // mitad de la VENTANA. Para que las dos mitades coincidan, la ventana abre ocupando todo.
    ventana.maximize();

    // Nada se abre dentro de la ventana fuera del teleprompter.
    ventana.webContents.setWindowOpenHandler(({ url }) => {
      if (/^https?:\/\//.test(url)) shell.openExternal(url);
      return { action: 'deny' };
    });
    ventana.webContents.on('will-navigate', (e, url) => {
      if (!url.startsWith(servidor.urlLocal)) e.preventDefault();
    });

    // Antes de cerrar, se guarda lo último que se escribió.
    ventana.on('close', async e => {
      if (cerrando) return;
      e.preventDefault();
      cerrando = true;
      try {
        await Promise.race([
          ventana.webContents.executeJavaScript('window.__guardarYa ? window.__guardarYa().then(() => true) : true'),
          new Promise(r => setTimeout(r, 1500)),
        ]);
      } catch (_) {}
      ventana.destroy();
    });
    ventana.on('closed', () => { ventana = null; });

    ventana.loadURL(servidor.urlLocal);
  });

  app.on('window-all-closed', async () => {
    try { if (servidor) await servidor.cerrar(); } catch (_) {}
    app.quit();
  });
}
