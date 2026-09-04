# BluHeli — Pilot v11

App iOS (SwiftUI + ExternalAccessory) para controlar el Silverlit Blue Sky Heli **BSH-A**
(accesorio MFi Bluetooth 2.1, nombre BT `Chatboard`).

## Protocolo confirmado (Build 16, el heli despegó)
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
