# Synco

Sincroniza clips de varias cámaras, teléfonos y grabadores comparando el audio, sin timecode.
Abrís el XML de tu línea de tiempo, tocás **Sincronizar** y exportás uno nuevo con cada clip en su
lugar, listo para volver a importar en el editor. App nativa de macOS, gratis y de código abierto.

Página: https://clipxel.github.io/Synco/

## Descargar

| Sistema | Archivo | Primera vez |
|---|---|---|
| macOS 13+ (Apple silicon e Intel) | `.dmg` universal, en **Releases** | Si macOS avisa que no puede verificarla: *Ajustes del Sistema › Privacidad y seguridad › Abrir igualmente* |

O desde la Terminal, que baja la última versión, verifica su SHA-256 y la copia a Aplicaciones:

```bash
curl -fsSL https://clipxel.github.io/Synco/install.sh | sh
```

Synco se actualiza sola: al abrirse se fija si hay una versión nueva y ofrece instalarla.

## Cómo se usa

1. En Premiere (o Resolve, Vegas): poné todos los clips de cámaras y grabadores en una secuencia y
   exportala como **Final Cut Pro XML**.
2. Abrí ese XML en Synco (o soltalo sobre la ventana) y tocá **Sincronizar**.
3. **Exportar** y, en el editor, *Archivo › Importar* el XML nuevo.

Lo que no tiene audio en común con nada se ubica por la hora de grabación del archivo y queda
marcado con otra etiqueta de color para revisarlo.

## Compilar

Solo hacen falta las herramientas de línea de comandos de Xcode (`xcode-select --install`).

```bash
engine/make_app.sh      # arma Synco.app
engine/make_dmg.sh      # arma dist/Synco-<versión>.dmg
```

La versión está en `engine/VERSION`. Cómo funciona el motor: [engine/README.md](engine/README.md).

## Publicar una versión

1. Subir el número en `engine/VERSION` y escribir las novedades en `.github/release-notes/v<versión>.md`.
2. `git tag v<versión> && git push --tags`.

GitHub Actions compila la app universal, arma el `.dmg`, crea el release y sube el `update.json`
(versión + SHA-256) que las copias instaladas leen para actualizarse solas. La página
(`website/`) se publica en GitHub Pages con cada push a `main`.

## Pruebas

```bash
e2e/update.sh           # la actualización automática, de punta a punta, en una carpeta temporal
e2e/run.sh proyecto.xml # abrir, sincronizar y exportar un proyecto real
```

## Contacto

Instagram [@nanobrunetti](https://www.instagram.com/nanobrunetti/). Si Synco te sirve, podés
[donar](https://onetouch.astropay.com/payment?external_reference_id=AERRP6sKfsrGdRunEEa6gJ7V5fQ1E0gO).

## Licencia

AGPL-3.0 (ver `LICENSE`).
