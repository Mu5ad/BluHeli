# BluHeli — Pilot v12

App iOS (SwiftUI + ExternalAccessory) para controlar el Silverlit Blue Sky Heli **BSH-A**
(accesorio MFi Bluetooth 2.1, nombre BT `Chatboard`).

## Protocolo REAL (ingeniería inversa del binario oficial sHelicopter, v12)

La app oficial envía **texto ASCII**: `"x"` + 10 dígitos hex minúsculas (`%llx` del entero de 40 bits, relleno a 5 bytes), UTF-8, sin checksum, a 20 Hz.
Campos: bits 0-4 trim (0..20, mid 10) · 5-7 luz (mid 4) · 8-15 yaw · 16-23 pitch · 24-31 rotor (0..128) · 38-39 canal btMatch.
Neutro canal B gas 0: `x40007f7f8a`. Respuesta del heli: 4 dígitos hex, bits 2-3 batería, bits 4-5 emergencia.

## Trama binaria de la Build 16 (histórico: hizo despegar el heli sin control)
Trama WeCCAN de 6 bytes a 20 Hz continuos, Canal C (match 2):

| Byte | Campo | Valor |
|------|-------|-------|
| 0 | luces | `0xF0` on / `0x00` off |
| 1 | trim | 0..32 (16 neutro) |
| 2 | yaw | 0..255 (127 neutro) |
| 3 | pitch | 0..255 (127 neutro) |
| 4 | gas | 0..255 (190 = despegue brusco, ~120 sustentación) |
| 5 | flags | `(match << 6) \| 0x2A` → Canal C = `0xAA` |

Trama que voló: `F0 0A 7F 7F BE AA`.

## Qué hace v11
- **Vuelo**: palanca de gas vertical (izq) + joystick pitch/yaw con retorno al centro (der), trim, STOP.
- **Cabina**: sliders, botón "mantener para volar" (suelta = gas 0), despegue/aterrizaje asistidos, ajustes.
- **Pruebas**: pulsos de 2 s con armado y rampa, rampa configurable, herramientas de conexión.
- Stream de 20 Hz en `RunLoop.Mode.common` (no se congela al arrastrar mandos).
- Armado (0,4 s a gas 0) → rampa de subida → bajada instantánea. Modo salón con tope al 65 %.
- Corte de gas si la app pasa a segundo plano o se cae el enlace MFi.

## Compilación
Push a `main` → GitHub Actions (macos-15, xcodegen) → Release `v4.<run>` con `BluHeli-unsigned.ipa`.
Instalar con Feather en el iPhone. Si el heli se apaga, reconectar en Ajustes → Bluetooth → Chatboard.
