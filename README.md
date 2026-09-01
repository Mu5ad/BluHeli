# BluHeli — mando nativo para tu Silverlit BluTechHeli (BSH-A) desde el iPhone

App SwiftUI que habla con el heli por **ExternalAccessory (el canal MFi que iOS ya te
demostró que funciona)** mandando el protocolo real de 5 bytes extraído del config.xml
oficial de Silverlit:

```
Byte 0: 0xB8   Byte 1: gas (64=stop, máx 128)   Byte 2: pitch (127 neutro)
Byte 3: yaw (127 neutro)   Byte 4: luces<<5 | trim   (neutro 0x38)
```

## Cómo generar la IPA (sin Mac, 5 minutos)

1. Crea un repo en github.com (botón New repository, nombre `BluHeli`, público o privado)
2. Sube TODO el contenido de esta carpeta (`.github` incluido — en GitHub actívalo
   con "Add file → Upload files" y arrastra las carpetas; ojo: las carpetas que
   empiezan por punto se suben bien por web)
3. Pestaña **Actions** del repo → si te avisa, pulsa "Enable workflows"
4. Entra en el workflow **"Build BluHeli"** → botón **Run workflow** → Run
5. En 3-5 minutos, en el resumen de la ejecución, sección **Artifacts**, descarga
   `BluHeli-unsigned-ipa` → dentro viene `BluHeli-unsigned.ipa`
6. Pásala al iPhone (AirDrop, iCloud, lo que sea) → **Feather → Import from Files →
   Sign con tu cert → Install**

## Qué hace la app

- **Escanea** accesorios MFi emparejados y lista sus protocolStrings (los "canales" MFi)
- Conecta con el que elijas (hay 8 protocolos candidatos pre-cargados)
- **Mando completo**: slider de GAS (64-128, con tope de seguridad configurable),
  PITCH, YAW, luces, STOP de emergencia, y envío continuo a 20 Hz (el heli necesita
  tramas constantes, si sueltas el enlace corta motores)
- **Log en vivo** de todo lo que entra/sale en hex

## Si el heli no aparece en la lista

Entonces iOS no le asigna ningún protocolo MFi compatible y la app no podrá abrirle
sesión (el emparejamiento fue solo un registro ACL). En ese caso el plan B es el PC:
`/opt/data/heli/silverlit_heli.py` ya tiene el protocolo y funciona con cualquier
adaptador Bluetooth clásico.
