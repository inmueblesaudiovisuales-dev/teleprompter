# Teleprompter

Teleprompter de escritorio para Mac que se controla desde el teléfono por Wi-Fi, sin internet.

- El texto corre en la mitad izquierda y los controles van en la derecha: el monitor donde se
  usa tiene una raya vertical a la mitad, así que nada importante pasa por el centro.
- Desde el teléfono (escaneando el QR) se pausa, se cambia velocidad y letra, y se elige
  desde qué palabra empezar.

## Carpetas

| Carpeta | Qué es |
|---|---|
| `swift/` | **La app vigente**, en Swift (~300 KB). `./construir.sh` arma `swift/build/Teleprompter.app` |
| `app/pantalla.html` | La pantalla (editor, teleprompter y control del teléfono). Fuente única: la app Swift la copia al armarse |
| `app/servidor.js`, `app/main.js` | La versión anterior en Electron. Se conserva como referencia y para las pruebas |
| `app/pruebas/` | Pruebas del servidor. Corren contra las dos versiones |
| `maquetas/` | Maquetas de diseño |

## Pruebas

```bash
cd app && npm install
npm test                                                     # contra la versión anterior
TP_SWIFT="$PWD/../swift/build/Teleprompter.app/Contents/MacOS/Teleprompter" npm test   # contra la app Swift
```

La app guarda el guion y la clave del QR en `~/Library/Application Support/Teleprompter/`.
