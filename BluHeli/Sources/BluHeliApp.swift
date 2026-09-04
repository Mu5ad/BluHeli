import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI PILOT v11 — MANDOS REALES + CABINA SEGURA PARA SALÓN
// Protocolo confirmado (Build 16): WeCCAN 6 bytes, Canal C (match 2).
//   Trama que despegó: F0 0A 7F 7F BE AA  (gas byte 190)
//
// Cambios clave respecto a v10:
//  1. Timers y streams en RunLoop.Mode.common: el modo .default se congela
//     mientras el dedo arrastra un Slider/joystick o hace scroll, y el stream
//     de 20 Hz se cortaba justo al acelerar. Ese era el fallo silencioso.
//  2. Pestaña VUELO: palanca de gas vertical (izq) + joystick pitch/yaw (der)
//     con retorno al centro, trim, STOP. Mandos tipo app original.
//  3. Máquina de estados de gas: armado (0,4 s a gas 0) -> rampa de subida
//     limitada -> bajada instantánea. Nunca salta de 0 a potencia alta.
//  4. Botón "mantener para volar": suelta el dedo = gas 0 al instante.
//  5. Modo salón: tope de gas (65 % = byte 166) para no repetir el cohete.
//  6. Corte de gas si la app pasa a segundo plano o el enlace se cae.
//  7. Medidor de Hz reales + detector de huecos en el stream (diagnóstico).
//  8. Lectura de la trama de respuesta del heli (nibble de batería, XML i737).
// =====================================================================

final class HeliPilot: NSObject, ObservableObject, StreamDelegate {

    static let versionApp = "Pilot v11"

    // ---------------- Estado del enlace ----------------
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0
    @Published var framesDescartados = 0
    @Published var hzReal = 0
    @Published var ultimaTramaHex = ""
    @Published var ultimaRxHex = ""
    @Published var bateriaNibble: Int? = nil

    // ---------------- Parámetros de vuelo ----------------
    @Published var gasObjetivo: Double = 0.0     // lo que pide el usuario (0..100 %)
    @Published var gasEnviado: Double = 0.0      // lo que realmente sale por el enlace (0..100 %)
    @Published var pitch: Double = 127.0         // 0..255, 127 neutro
    @Published var yaw: Double = 127.0           // 0..255, 127 neutro
    @Published var trim: Int = 16                // 0..32, 16 neutro (XML i737)
    @Published var match: Int = 2                // 0=A rojo, 1=B verde, 2=C azul (confirmado)
    @Published var luces: Bool = true
    @Published var modoSalon: Bool = true        // tope de gas al 65 %
    @Published var autoCentrar: Bool = true      // pitch/yaw vuelven a 127 al soltar (sliders)
    @Published var gasSpring: Bool = false       // palanca de gas: al soltar -> 0
    @Published var sensibilidad: Double = 0.7    // recorrido del joystick (0.3..1.0)
    @Published var invertirYaw: Bool = false
    @Published var invertirPitch: Bool = false
    @Published var potenciaMantener: Double = 55 // % del botón "mantener para volar"
    @Published var potenciaDespegue: Double = 50 // % del despegue asistido
    @Published var rampaPorTick: Double = 2.5    // % por tick (20 Hz) => 50 %/s
    @Published var armado = false
    @Published var maniobraActiva = false

    let topeSalon: Double = 65.0
    let ticksArmado = 8                          // 8 tramas a gas 0 = 0,4 s

    var topeActual: Double { modoSalon ? topeSalon : 100.0 }

    // ---------------- Internos ----------------
    private var session: EASession?
    private var timerTx: Timer?
    private var timerAuto: Timer?
    private var timerManiobra: Timer?
    private var ticksEnCero = 0
    private var contadorHz = 0
    private var tUltimoHz = Date()
    private var tUltimoTick = Date()
    private var tUltimoLogRx = Date(timeIntervalSince1970: 0)
    private var accesorioActualID: Int = -1

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioConectado(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioDesconectado(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)

        // Timers en modo .common: siguen disparando aunque el usuario arrastre un slider.
        let ta = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
        RunLoop.main.add(ta, forMode: .common)
        timerAuto = ta

        let tt = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tt.tolerance = 0.005
        RunLoop.main.add(tt, forMode: .common)
        timerTx = tt

        agregarLog("\(HeliPilot.versionApp) listo. Esperando accesorio MFi (Chatboard)...")
    }

    deinit {
        timerTx?.invalidate()
        timerAuto?.invalidate()
        timerManiobra?.invalidate()
    }

    // =================================================================
    // CONEXIÓN MFi
    // =================================================================
    @objc private func accesorioConectado(_ notification: Notification) {
        agregarLog("NOTIF: iOS ha conectado un accesorio.")
        if !conectado { buscarYConectarAuto() }
    }

    @objc private func accesorioDesconectado(_ notification: Notification) {
        let acc = notification.userInfo?[EAAccessoryKey] as? EAAccessory
        if let acc = acc, accesorioActualID != -1, acc.connectionID != accesorioActualID {
            agregarLog("NOTIF: se desconectó otro accesorio (\(acc.name)), ignorado.")
            return
        }
        agregarLog("NOTIF: Helicóptero desconectado. Gas a 0.")
        cerrarSesion()
    }

    func abrirSelectorBluetoothMFi() {
        agregarLog("Abriendo selector Bluetooth MFi de Apple...")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil, completion: { [weak self] error in
            if let err = error {
                self?.agregarLog("Selector MFi: \(err.localizedDescription)")
            } else {
                self?.agregarLog("Accesorio seleccionado en el diálogo MFi.")
                self?.buscarYConectarAuto()
            }
        })
    }

    func buscarYConectarAuto() {
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty { return }
        let preferidos = ["com.silverlit.datapath", "com.issc.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
        for acc in accesorios {
            for proto in preferidos where acc.protocolStrings.contains(proto) {
                if conectar(acc: acc, proto: proto) { return }
            }
            if let primero = acc.protocolStrings.first {
                if conectar(acc: acc, proto: primero) { return }
            }
        }
    }

    func conectar(acc: EAAccessory, proto: String) -> Bool {
        cerrarSesion()
        agregarLog("Conectando con \(acc.name) [\(proto)]...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error: no se pudo abrir EASession con '\(proto)'.")
            return false
        }
        session = ses
        nombreDispositivo = acc.name
        protoActivo = proto
        accesorioActualID = acc.connectionID

        if let inp = ses.inputStream {
            inp.delegate = self
            inp.schedule(in: .main, forMode: .common)
            inp.open()
        }
        if let out = ses.outputStream {
            out.delegate = self
            out.schedule(in: .main, forMode: .common)
            out.open()
        }

        gasObjetivo = 0
        gasEnviado = 0
        ticksEnCero = 0
        armado = false
        framesEnviados = 0
        framesDescartados = 0
        conectado = true
        agregarLog(">>> CONECTADO a \(acc.name). Stream 20 Hz activo (gas 0). <<<")
        return true
    }

    func cerrarSesion() {
        if let ses = session {
            ses.inputStream?.close()
            ses.outputStream?.close()
            ses.inputStream?.remove(from: .main, forMode: .common)
            ses.outputStream?.remove(from: .main, forMode: .common)
        }
        session = nil
        accesorioActualID = -1
        conectado = false
        nombreDispositivo = ""
        protoActivo = ""
        timerManiobra?.invalidate()
        maniobraActiva = false
        gasObjetivo = 0
        gasEnviado = 0
        armado = false
        hzReal = 0
    }

    // =================================================================
    // BUCLE DE 20 Hz
    // =================================================================
    private func tick() {
        let ahora = Date()
        let hueco = ahora.timeIntervalSince(tUltimoTick)
        tUltimoTick = ahora
        if conectado && hueco > 0.25 {
            agregarLog(String(format: "⚠️ Hueco en el stream: %.0f ms sin tramas", hueco * 1000))
        }
        guard conectado else { return }

        actualizarGas()
        enviarTramaVueloActual()

        contadorHz += 1
        if ahora.timeIntervalSince(tUltimoHz) >= 1.0 {
            hzReal = contadorHz
            contadorHz = 0
            tUltimoHz = ahora
        }
    }

    // Máquina de estados del gas: armado -> rampa de subida -> bajada instantánea
    private func actualizarGas() {
        let objetivo = Swift.min(Swift.max(0.0, gasObjetivo), topeActual)

        if objetivo <= 0 {
            gasEnviado = 0
            ticksEnCero = Swift.min(ticksEnCero + 1, 100_000)
            armado = ticksEnCero >= ticksArmado
            return
        }

        // Estamos en 0 y se acaba de pedir gas: completar el armado antes de subir.
        if gasEnviado <= 0 && ticksEnCero < ticksArmado {
            ticksEnCero += 1
            armado = ticksEnCero >= ticksArmado
            if !armado { return }
            agregarLog("✅ Armado completado (\(ticksArmado) tramas a gas 0). Subiendo hacia \(Int(objetivo)) %.")
        }

        if gasEnviado <= 0 {
            agregarLog("▶️ Motores: rampa hacia \(Int(objetivo)) % (byte \(byteGas(objetivo))).")
        }

        if objetivo > gasEnviado {
            gasEnviado = Swift.min(objetivo, gasEnviado + rampaPorTick)
        } else {
            gasEnviado = objetivo   // bajar es siempre inmediato
        }
        ticksEnCero = 0
        armado = true
    }

    // =================================================================
    // TRAMA WECCAN 6 BYTES (idéntica a la que voló en Build 16)
    // =================================================================
    func byteGas(_ porcentaje: Double) -> Int {
        let v = (Swift.max(0.0, Swift.min(100.0, porcentaje)) / 100.0) * 255.0
        return Int(v.rounded())
    }

    func generarBytesWeccan(gasPorcentaje: Double, pitchVal: Double, yawVal: Double, trimVal: Int, luzVal: Bool, matchCanal: Int) -> [UInt8] {
        let b0: UInt8 = luzVal ? 0xF0 : 0x00
        let t = UInt8(Swift.max(0, Swift.min(32, trimVal)))
        let y = UInt8(Swift.max(0, Swift.min(255, Int(yawVal))))
        let p = UInt8(Swift.max(0, Swift.min(255, Int(pitchVal))))
        let g = UInt8(Swift.max(0, Swift.min(255, byteGas(gasPorcentaje))))
        let flags = UInt8(((matchCanal & 3) << 6) | 0x2A)   // trimFlag=2, yawFlag=2, pitchFlag=2
        return [b0, t, y, p, g, flags]
    }

    private func enviarTramaVueloActual() {
        let bytes = generarBytesWeccan(gasPorcentaje: gasEnviado, pitchVal: pitch, yawVal: yaw,
                                       trimVal: trim, luzVal: luces, matchCanal: match)
        if !escribirBytes(bytes) { framesDescartados += 1 }
    }

    @discardableResult
    func escribirBytes(_ bytes: [UInt8]) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else { return false }
        let n = out.write(bytes, maxLength: bytes.count)
        if n == bytes.count {
            framesEnviados += 1
            ultimaTramaHex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            return true
        }
        return false
    }

    // =================================================================
    // ACCIONES DE VUELO
    // =================================================================

    /// Joystick: dx, dy en -1...1 (dy positivo = hacia abajo en pantalla).
    func aplicarJoystick(dx: Double, dy: Double) {
        let s = Swift.max(0.1, Swift.min(1.0, sensibilidad))
        var y = 127.0 + dx * 127.0 * s
        var p = 127.0 - dy * 127.0 * s          // arrastrar hacia arriba = adelante
        if invertirYaw { y = 254.0 - y }
        if invertirPitch { p = 254.0 - p }
        yaw = Swift.max(0.0, Swift.min(255.0, y))
        pitch = Swift.max(0.0, Swift.min(255.0, p))
    }

    func centrarJoystick() {
        yaw = 127
        pitch = 127
    }

    /// Palanca de gas: valor absoluto 0..100 pedido desde la pestaña Vuelo.
    func fijarGas(_ valor: Double) {
        guard !maniobraActiva else { return }
        gasObjetivo = Swift.max(0.0, Swift.min(100.0, valor))
    }

    func ajustarTrim(_ delta: Int) {
        trim = Swift.max(0, Swift.min(32, trim + delta))
    }

    /// Botón "mantener para volar": true al pulsar, false al soltar.
    func mantener(_ pulsado: Bool) {
        guard !maniobraActiva else { return }
        if pulsado {
            guard conectado else { agregarLog("No conectado: pulsa Vincular."); return }
            gasObjetivo = potenciaMantener
        } else {
            if gasObjetivo > 0 { agregarLog("Soltado: gas 0.") }
            gasObjetivo = 0
        }
    }

    /// Pulso de potencia fija con parada automática (el armado y la rampa los hace el bucle).
    func ejecutarPulso(potencia: Double, duracion: Double = 2.0) {
        guard conectado else { agregarLog("No conectado: pulsa Vincular."); return }
        guard !maniobraActiva else { return }
        maniobraActiva = true
        let efectiva = Swift.min(potencia, topeActual)
        if efectiva < potencia { agregarLog("Modo salón activo: tope \(Int(topeActual)) % (byte \(byteGas(topeActual))).") }
        let tRampa = (efectiva / Swift.max(0.1, rampaPorTick)) * 0.05
        let total = Double(ticksArmado) * 0.05 + tRampa + duracion
        agregarLog(String(format: "=== PULSO %ld %% (byte %ld) durante %.1f s + armado/rampa %.1f s ===",
                          Int(efectiva), byteGas(efectiva), duracion, total - duracion))
        gasObjetivo = efectiva
        programarManiobra(intervalo: total, repite: false) { [weak self] _ in
            guard let self = self else { return }
            self.gasObjetivo = 0
            self.maniobraActiva = false
            self.agregarLog("Fin de pulso. Gas 0.")
        }
    }

    func despegueSuave() {
        guard conectado, !maniobraActiva else { return }
        let obj = Swift.min(potenciaDespegue, topeActual)
        agregarLog("🛫 Despegue asistido hacia \(Int(obj)) % (byte \(byteGas(obj))). El gas queda fijo: usa Aterrizar o STOP.")
        gasObjetivo = obj
    }

    func aterrizarSuave() {
        guard conectado else { return }
        guard !maniobraActiva else { return }
        maniobraActiva = true
        agregarLog("🛬 Aterrizaje asistido: bajando 2 % cada 80 ms...")
        programarManiobra(intervalo: 0.08, repite: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.gasObjetivo = Swift.max(0.0, self.gasObjetivo - 2.0)
            if self.gasObjetivo <= 0 {
                t.invalidate()
                self.maniobraActiva = false
                self.agregarLog("Aterrizado. Gas 0.")
            }
        }
    }

    func paradaTotalEmergencia(motivo: String = "botón STOP") {
        timerManiobra?.invalidate()
        maniobraActiva = false
        gasObjetivo = 0
        gasEnviado = 0
        pitch = 127
        yaw = 127
        let stop = generarBytesWeccan(gasPorcentaje: 0, pitchVal: 127, yawVal: 127, trimVal: trim, luzVal: luces, matchCanal: match)
        for _ in 0..<10 { escribirBytes(stop) }
        agregarLog("🛑 PARADA TOTAL (\(motivo)): gas 0, ráfaga de 10 tramas de parada.")
    }

    private func programarManiobra(intervalo: TimeInterval, repite: Bool, bloque: @escaping (Timer) -> Void) {
        timerManiobra?.invalidate()
        let t = Timer(timeInterval: intervalo, repeats: repite, block: bloque)
        RunLoop.main.add(t, forMode: .common)
        timerManiobra = t
    }

    // =================================================================
    // STREAM DELEGATE (eventos + lectura de la respuesta del heli)
    // =================================================================
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            leerEntrada()
        case .errorOccurred:
            let desc = aStream.streamError?.localizedDescription ?? "desconocido"
            agregarLog("STREAM: error de enlace (\(desc)).")
        case .endEncountered:
            agregarLog("STREAM: conexión cerrada por el accesorio.")
            cerrarSesion()
        default:
            break
        }
    }

    private func leerEntrada() {
        guard let inp = session?.inputStream else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        var leidos: [UInt8] = []
        while inp.hasBytesAvailable {
            let n = inp.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            leidos.append(contentsOf: buf[0..<n])
        }
        guard !leidos.isEmpty else { return }
        ultimaRxHex = leidos.map { String(format: "%02X", $0) }.joined(separator: " ")
        // XML i737: respuesta de 2 bytes, byte 1 bits 0..3 = batería (0..15)
        if leidos.count >= 2 {
            bateriaNibble = Int(leidos[leidos.count - 1] & 0x0F)
        }
        if Date().timeIntervalSince(tUltimoLogRx) > 2.0 {
            tUltimoLogRx = Date()
            agregarLog("RX heli: \(ultimaRxHex)")
        }
    }

    func agregarLog(_ s: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        log = "[\(df.string(from: Date()))] \(s)\n" + log
        if log.count > 15000 { log = String(log.prefix(15000)) }
    }
}

// =====================================================================
// MARK: - Raíz
// =====================================================================
struct ContentView: View {
    @StateObject private var pilot = HeliPilot()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            VueloView(pilot: pilot).tabItem { Label("Vuelo", systemImage: "gamecontroller.fill") }
            CabinaView(pilot: pilot).tabItem { Label("Cabina", systemImage: "slider.horizontal.3") }
            PruebasView(pilot: pilot).tabItem { Label("Pruebas", systemImage: "bolt.horizontal.fill") }
            ConsolaView(pilot: pilot).tabItem { Label("Consola", systemImage: "terminal.fill") }
        }
        .onChange(of: scenePhase) { fase in
            if fase != .active && (pilot.gasObjetivo > 0 || pilot.gasEnviado > 0) {
                pilot.paradaTotalEmergencia(motivo: "app en segundo plano")
            }
        }
    }
}

func nombreCanal(_ m: Int) -> String {
    switch m {
    case 0: return "A rojo"
    case 1: return "B verde"
    case 2: return "C azul"
    default: return "m\(m)"
    }
}

// =====================================================================
// MARK: - TAB VUELO: mandos reales (palanca de gas + joystick)
// =====================================================================
struct VueloView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width > geo.size.height
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                VStack(spacing: 8) {
                    barraSuperior
                    HStack(alignment: .center, spacing: 12) {
                        PalancaGas(pilot: pilot)
                            .frame(width: horizontal ? 110 : 90)
                        VStack(spacing: 10) {
                            panelCentral
                            Spacer(minLength: 0)
                            botonesTrim
                        }
                        .frame(maxWidth: .infinity)
                        JoystickPad(pilot: pilot)
                            .frame(width: ladoJoystick(geo), height: ladoJoystick(geo))
                    }
                    .frame(maxHeight: .infinity)
                    barraInferior
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if !pilot.conectado {
                    overlayDesconectado
                }
            }
        }
    }

    private func ladoJoystick(_ geo: GeometryProxy) -> CGFloat {
        let disponibleAlto = geo.size.height - 150
        let disponibleAncho = geo.size.width - 90 - 12 - 12 - 24 - 110
        return Swift.max(160, Swift.min(320, Swift.min(disponibleAlto, disponibleAncho)))
    }

    var barraSuperior: some View {
        HStack(spacing: 10) {
            Circle().fill(pilot.conectado ? Color.green : Color.red).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: pilot.conectado ? pilot.nombreDispositivo : "Desconectado").font(.caption).bold()
                Text(verbatim: pilot.conectado ? "\(pilot.hzReal) Hz · \(nombreCanal(pilot.match)) · \(pilot.armado ? "ESC listo" : "armando…")" : "Ajustes → Bluetooth → Chatboard")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { pilot.luces.toggle() }) {
                Image(systemName: pilot.luces ? "lightbulb.fill" : "lightbulb")
                    .foregroundColor(pilot.luces ? .yellow : .secondary)
                    .padding(8)
            }
            .buttonStyle(.bordered)
            Button(action: { pilot.paradaTotalEmergencia() }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                    Text("STOP").bold()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.top, 4)
    }

    var panelCentral: some View {
        VStack(spacing: 6) {
            Text(verbatim: "GAS").font(.caption2).foregroundColor(.secondary)
            Text(verbatim: "\(Int(pilot.gasEnviado)) %")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundColor(pilot.gasEnviado > 0 ? (pilot.gasEnviado > 60 ? .red : .green) : .secondary)
            Text(verbatim: "obj \(Int(pilot.gasObjetivo)) % · byte \(pilot.byteGas(pilot.gasEnviado))")
                .font(.caption2).foregroundColor(.secondary)
            if pilot.modoSalon {
                Text(verbatim: "SALÓN · tope \(Int(pilot.topeSalon)) %")
                    .font(.caption2).bold().foregroundColor(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15)).cornerRadius(6)
            } else {
                Text(verbatim: "LIBRE · sin tope")
                    .font(.caption2).bold().foregroundColor(.red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.15)).cornerRadius(6)
            }
            Divider()
            HStack {
                VStack { Text(verbatim: "PITCH").font(.caption2).foregroundColor(.secondary); Text(verbatim: "\(Int(pilot.pitch))").font(.footnote).bold().monospacedDigit() }
                Spacer()
                VStack { Text(verbatim: "YAW").font(.caption2).foregroundColor(.secondary); Text(verbatim: "\(Int(pilot.yaw))").font(.footnote).bold().monospacedDigit() }
            }
            .padding(.horizontal, 4)
        }
    }

    var botonesTrim: some View {
        VStack(spacing: 4) {
            Text(verbatim: "TRIM \(pilot.trim)").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button(action: { pilot.ajustarTrim(-1) }) {
                    Image(systemName: "arrow.turn.up.left").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button(action: { pilot.trim = 16 }) {
                    Text(verbatim: "16").font(.caption).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button(action: { pilot.ajustarTrim(1) }) {
                    Image(systemName: "arrow.turn.up.right").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    var barraInferior: some View {
        HStack {
            Text(verbatim: "TX \(pilot.ultimaTramaHex.isEmpty ? "--" : pilot.ultimaTramaHex)")
                .font(.system(.caption2, design: .monospaced)).foregroundColor(.blue)
            Spacer()
            if let b = pilot.bateriaNibble {
                Text(verbatim: "🔋 \(b)/15").font(.caption2)
            }
            Text(verbatim: "\(pilot.framesEnviados) tx")
                .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    var overlayDesconectado: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 44))
            Text(verbatim: "Helicóptero desconectado").font(.title3).bold()
            Text(verbatim: "Enciende el heli. Si iOS no lo reconecta solo, ve a Ajustes → Bluetooth → Chatboard, o pulsa Vincular. Los mandos se activan solos al conectar.")
                .font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
            Button(action: { pilot.abrirSelectorBluetoothMFi() }) {
                Text(verbatim: "📲 VINCULAR / RECONECTAR").bold().padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(24)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.97))
        .cornerRadius(18)
        .padding(30)
    }
}

// Palanca vertical de gas. Arrastre relativo (el dedo mueve el valor desde donde estaba).
struct PalancaGas: View {
    @ObservedObject var pilot: HeliPilot
    @State private var gasInicioDrag: Double? = nil

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let w = g.size.width
            let tope = pilot.topeActual
            let alturaKnob: CGFloat = 30
            let recorrido = Swift.max(1, h - alturaKnob)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(UIColor.secondarySystemBackground))
                // Zona prohibida por el tope (modo salón)
                if tope < 100 {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.red.opacity(0.14))
                            .frame(height: h * CGFloat(1.0 - tope / 100.0))
                        Spacer(minLength: 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                // Relleno: gas realmente enviado
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.green.opacity(0.35))
                    .frame(height: Swift.max(0, h * CGFloat(pilot.gasEnviado / 100.0)))
                // Marcas
                VStack {
                    ForEach([100, 75, 50, 25], id: \.self) { m in
                        Text(verbatim: "\(m)").font(.system(size: 9)).foregroundColor(.secondary)
                        Spacer()
                    }
                    Text(verbatim: "0").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
                // Knob: gas objetivo
                Capsule()
                    .fill(pilot.maniobraActiva ? Color.gray : Color.orange)
                    .frame(width: w - 10, height: alturaKnob)
                    .overlay(Text(verbatim: "\(Int(pilot.gasObjetivo))").font(.caption).bold().foregroundColor(.white))
                    .offset(y: -recorrido * CGFloat(pilot.gasObjetivo / 100.0))
                    .padding(.bottom, 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard pilot.conectado, !pilot.maniobraActiva else { return }
                        if gasInicioDrag == nil { gasInicioDrag = pilot.gasObjetivo }
                        let delta = Double(-v.translation.height / recorrido) * 100.0
                        pilot.fijarGas((gasInicioDrag ?? 0) + delta)
                    }
                    .onEnded { _ in
                        gasInicioDrag = nil
                        if pilot.gasSpring { pilot.fijarGas(0) }
                    }
            )
        }
    }
}

// Joystick de dirección: X = yaw, Y = pitch. Vuelve al centro al soltar.
struct JoystickPad: View {
    @ObservedObject var pilot: HeliPilot
    @State private var pos: CGSize = .zero
    @State private var activo = false

    var body: some View {
        GeometryReader { g in
            let lado = Swift.min(g.size.width, g.size.height)
            let radioKnob: CGFloat = 34
            let r = Swift.max(20, lado / 2 - radioKnob)
            ZStack {
                Circle().fill(Color(UIColor.secondarySystemBackground))
                Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                    .frame(width: r * 2, height: r * 2)
                Path { p in
                    p.move(to: CGPoint(x: lado / 2, y: lado / 2 - r)); p.addLine(to: CGPoint(x: lado / 2, y: lado / 2 + r))
                    p.move(to: CGPoint(x: lado / 2 - r, y: lado / 2)); p.addLine(to: CGPoint(x: lado / 2 + r, y: lado / 2))
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                VStack {
                    Text(verbatim: "▲ adelante").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(verbatim: "▼ atrás").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(6)
                HStack {
                    Text(verbatim: "◀ izq").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(verbatim: "der ▶").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(6)
                Circle()
                    .fill(activo ? Color.blue : (pilot.conectado ? Color.blue.opacity(0.75) : Color.gray))
                    .frame(width: radioKnob * 2, height: radioKnob * 2)
                    .shadow(radius: activo ? 6 : 2)
                    .offset(pos)
            }
            .frame(width: lado, height: lado)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard pilot.conectado else { return }
                        var dx = v.location.x - g.size.width / 2
                        var dy = v.location.y - g.size.height / 2
                        let d = sqrt(dx * dx + dy * dy)
                        if d > r { dx *= r / d; dy *= r / d }
                        pos = CGSize(width: dx, height: dy)
                        activo = true
                        pilot.aplicarJoystick(dx: Double(dx / r), dy: Double(dy / r))
                    }
                    .onEnded { _ in
                        pos = .zero
                        activo = false
                        pilot.centrarJoystick()
                    }
            )
        }
    }
}

// =====================================================================
// MARK: - TAB CABINA: sliders, mantener, maniobras, ajustes
// =====================================================================
struct CabinaView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                seccionConexion
                seccionStop
                seccionGas
                seccionMantener
                seccionDespegue
                seccionDireccion
                seccionAjustesMandos
                seccionTrama
            }
            .navigationTitle("BluHeli \(HeliPilot.versionApp)")
        }
    }

    var seccionConexion: some View {
        Section {
            HStack {
                Circle().fill(pilot.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pilot.conectado ? "CONECTADO: \(pilot.nombreDispositivo)" : "🔴 HELICÓPTERO DESCONECTADO").bold()
                    if pilot.conectado {
                        Text(verbatim: "Canal \(nombreCanal(pilot.match)) · \(pilot.hzReal) Hz · \(pilot.framesEnviados) tx · \(pilot.framesDescartados) desc")
                            .font(.caption2).foregroundColor(.secondary)
                        if let b = pilot.bateriaNibble {
                            Text(verbatim: "Batería (nibble RX): \(b)/15").font(.caption2).foregroundColor(.secondary)
                        }
                    } else {
                        Text(verbatim: "Enciende el heli. Si no conecta solo: Ajustes → Bluetooth → Chatboard, o pulsa Vincular.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if pilot.conectado {
                    Text(verbatim: pilot.armado ? "ESC listo" : "armando…")
                        .font(.caption2).bold()
                        .foregroundColor(pilot.armado ? .green : .orange)
                }
            }
            if !pilot.conectado {
                Button(action: { pilot.abrirSelectorBluetoothMFi() }) {
                    HStack {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(verbatim: "📲 VINCULAR / RECONECTAR BLUETOOTH").bold()
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }

    var seccionStop: some View {
        Section {
            Button(action: { pilot.paradaTotalEmergencia() }) {
                HStack {
                    Spacer()
                    Image(systemName: "stop.circle.fill").font(.title2)
                    Text(verbatim: "STOP · CORTE TOTAL DE MOTOR").font(.headline).bold()
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    var seccionGas: some View {
        Section(header: Text(verbatim: "GAS").bold()) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Objetivo").bold()
                    Spacer()
                    Text(verbatim: "\(Int(pilot.gasObjetivo)) %").font(.title2).bold()
                        .foregroundColor(pilot.gasObjetivo > 0 ? .orange : .secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Enviado al heli").bold()
                    Spacer()
                    Text(verbatim: "\(Int(pilot.gasEnviado)) %  ·  byte \(pilot.byteGas(pilot.gasEnviado))")
                        .font(.title3).bold()
                        .foregroundColor(pilot.gasEnviado > 0 ? (pilot.gasEnviado > 60 ? .red : .green) : .secondary)
                }
                Slider(value: $pilot.gasObjetivo, in: 0...100, step: 1)
                    .tint(pilot.gasObjetivo > 0 ? .orange : .gray)
                    .disabled(pilot.maniobraActiva)
                Text(verbatim: "El gas sube en rampa (\(String(format: "%.1f", pilot.rampaPorTick)) % por tick ≈ \(Int(pilot.rampaPorTick * 20)) %/s) y baja al instante.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Toggle(isOn: $pilot.modoSalon) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Modo salón (tope \(Int(pilot.topeSalon)) % = byte \(pilot.byteGas(pilot.topeSalon)))").bold()
                    Text(verbatim: "Desactívalo solo en exterior. La Build 16 salió disparada con byte 190 (75 %).")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .tint(.green)
        }
    }

    var seccionMantener: some View {
        Section(header: Text(verbatim: "MANTENER PARA VOLAR (suelta = gas 0)").bold()) {
            HStack {
                Text(verbatim: "Potencia").bold()
                Slider(value: $pilot.potenciaMantener, in: 10...100, step: 1)
                Text(verbatim: "\(Int(pilot.potenciaMantener)) % · b\(pilot.byteGas(pilot.potenciaMantener))")
                    .font(.caption).monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            BotonMantener(pilot: pilot)
        }
    }

    var seccionDespegue: some View {
        Section(header: Text(verbatim: "MANIOBRAS ASISTIDAS").bold()) {
            HStack {
                Text(verbatim: "Despegue a").bold()
                Slider(value: $pilot.potenciaDespegue, in: 10...100, step: 1)
                Text(verbatim: "\(Int(pilot.potenciaDespegue)) %").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Button(action: { pilot.despegueSuave() }) {
                    HStack { Spacer(); Image(systemName: "arrow.up.circle.fill"); Text(verbatim: "🛫 DESPEGAR").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(pilot.maniobraActiva || !pilot.conectado)

                Button(action: { pilot.aterrizarSuave() }) {
                    HStack { Spacer(); Image(systemName: "arrow.down.circle.fill"); Text(verbatim: "🛬 ATERRIZAR").bold(); Spacer() }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(pilot.gasObjetivo <= 0 || pilot.maniobraActiva)
            }
            .padding(.vertical, 4)
        }
    }

    var seccionDireccion: some View {
        Section(header: Text(verbatim: "DIRECCIÓN").bold()) {
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Pitch (atrás 0 · adelante 255)").bold(); Spacer(); Text(verbatim: "\(Int(pilot.pitch))").font(.caption) }
                Slider(value: $pilot.pitch, in: 0...255, step: 1, onEditingChanged: { editando in
                    if !editando && pilot.autoCentrar { pilot.pitch = 127 }
                })
            }
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Yaw (izq 0 · der 255)").bold(); Spacer(); Text(verbatim: "\(Int(pilot.yaw))").font(.caption) }
                Slider(value: $pilot.yaw, in: 0...255, step: 1, onEditingChanged: { editando in
                    if !editando && pilot.autoCentrar { pilot.yaw = 127 }
                })
            }
            Toggle(isOn: $pilot.autoCentrar) { Text(verbatim: "Auto‑centrar pitch/yaw al soltar (sliders)") }

            HStack {
                Picker(selection: $pilot.trim) {
                    ForEach(0..<33) { Text(verbatim: "\($0)").tag($0) }
                } label: { Text(verbatim: "Trim") }
                .pickerStyle(.menu)
                Spacer()
                Toggle(isOn: $pilot.luces) { Text(verbatim: "Faros") }.tint(.yellow)
            }

            Picker(selection: $pilot.match) {
                Text(verbatim: "🔴 A").tag(0)
                Text(verbatim: "🟢 B").tag(1)
                Text(verbatim: "🔵 C ✓").tag(2)
            } label: { Text(verbatim: "Canal") }
            .pickerStyle(.segmented)

            Button(action: { pilot.pitch = 127; pilot.yaw = 127; pilot.trim = 16 }) {
                Text(verbatim: "🎯 Centrar (Pitch 127 · Yaw 127 · Trim 16)")
            }
            .font(.footnote)
        }
    }

    var seccionAjustesMandos: some View {
        Section(header: Text(verbatim: "AJUSTES DE LOS MANDOS (pestaña Vuelo)").bold()) {
            Toggle(isOn: $pilot.gasSpring) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Palanca de gas: al soltar → 0").bold()
                    Text(verbatim: "Apagado = la palanca se queda donde la dejas (como un mando RC).").font(.caption2).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text(verbatim: "Sensibilidad del joystick").bold()
                    Spacer()
                    Text(verbatim: "\(Int(pilot.sensibilidad * 100)) %").font(.caption)
                }
                Slider(value: $pilot.sensibilidad, in: 0.3...1.0, step: 0.05)
                Text(verbatim: "Recorrido máximo de pitch/yaw al llevar el joystick al borde. 70 % es cómodo en salón.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Toggle(isOn: $pilot.invertirYaw) { Text(verbatim: "Invertir yaw (giro)") }
            Toggle(isOn: $pilot.invertirPitch) { Text(verbatim: "Invertir pitch (adelante/atrás)") }
        }
    }

    var seccionTrama: some View {
        Section {
            HStack {
                Text(verbatim: "TX:").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(verbatim: pilot.ultimaTramaHex.isEmpty ? "--" : pilot.ultimaTramaHex)
                    .font(.system(.footnote, design: .monospaced)).bold().foregroundColor(.blue)
            }
            HStack {
                Text(verbatim: "RX:").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(verbatim: pilot.ultimaRxHex.isEmpty ? "--" : pilot.ultimaRxHex)
                    .font(.system(.footnote, design: .monospaced)).foregroundColor(.purple)
            }
        }
    }
}

// Botón de "mantener pulsado": gas mientras el dedo está encima, 0 al soltar
// o al salir del área. No usa Button para poder seguir el estado de presión.
struct BotonMantener: View {
    @ObservedObject var pilot: HeliPilot
    @State private var pulsado = false

    var body: some View {
        let activo = pilot.conectado && !pilot.maniobraActiva
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(!activo ? Color.gray.opacity(0.35) : (pulsado ? Color.red : Color.orange))
            VStack(spacing: 4) {
                Image(systemName: pulsado ? "flame.fill" : "hand.tap.fill").font(.title)
                Text(verbatim: pulsado ? "VOLANDO · SUELTA PARA PARAR" : "MANTENER PULSADO PARA VOLAR")
                    .font(.headline).bold()
                Text(verbatim: "\(Int(pilot.potenciaMantener)) % · byte \(pilot.byteGas(pilot.potenciaMantener))")
                    .font(.caption)
            }
            .foregroundColor(.white)
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, pressing: { presionando in
            guard activo else { return }
            pulsado = presionando
            pilot.mantener(presionando)
        }, perform: {})
        .onDisappear {
            if pulsado { pulsado = false; pilot.mantener(false) }
        }
    }
}

// =====================================================================
// MARK: - TAB PRUEBAS
// =====================================================================
struct PruebasView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(verbatim: "Pulsos de 2 s con armado y rampa (sujeta el heli)"),
                        footer: Text(verbatim: "Cada pulso envía 0,4 s a gas 0, sube en rampa hasta la potencia y la mantiene 2 s. El modo salón limita al \(Int(pilot.topeSalon)) %.")) {
                    Button(action: { pilot.ejecutarPulso(potencia: 40) }) { Text(verbatim: "⚡ Pulso 40 % (byte 102) — ¿giran las palas?") }
                    Button(action: { pilot.ejecutarPulso(potencia: 50) }) { Text(verbatim: "⚡ Pulso 50 % (byte 128) — sustentación baja") }
                    Button(action: { pilot.ejecutarPulso(potencia: 60) }) { Text(verbatim: "⚡ Pulso 60 % (byte 153) — vuelo salón") }
                    Button(action: { pilot.ejecutarPulso(potencia: 74.5) }) {
                        Text(verbatim: "🔥 Réplica Build 16: 75 % (byte 190) — solo exterior").foregroundColor(.red)
                    }
                }
                .disabled(pilot.maniobraActiva || !pilot.conectado)

                Section(header: Text(verbatim: "Rampa de subida del gas")) {
                    Picker(selection: $pilot.rampaPorTick) {
                        Text(verbatim: "Suave 30 %/s").tag(1.5)
                        Text(verbatim: "Normal 50 %/s").tag(2.5)
                        Text(verbatim: "Rápida 100 %/s").tag(5.0)
                    } label: { Text(verbatim: "Rampa") }
                    .pickerStyle(.segmented)
                }

                Section(header: Text(verbatim: "Conexión")) {
                    Button(action: { pilot.abrirSelectorBluetoothMFi() }) { Text(verbatim: "📲 Abrir selector Bluetooth MFi de Apple") }
                    Button(action: { pilot.buscarYConectarAuto() }) { Text(verbatim: "🔄 Reconectar automático") }
                    Button(action: { pilot.cerrarSesion() }) { Text(verbatim: "✂️ Cerrar sesión MFi").foregroundColor(.red) }
                    HStack {
                        Text(verbatim: "Protocolo").foregroundColor(.secondary)
                        Spacer()
                        Text(verbatim: pilot.protoActivo.isEmpty ? "--" : pilot.protoActivo).font(.caption)
                    }
                }

                Section(header: Text(verbatim: "Referencia de trama (6 bytes WeCCAN)")) {
                    Text(verbatim: "B0 luces F0/00 · B1 trim 0‑32 · B2 yaw · B3 pitch · B4 gas 0‑255 · B5 flags (canal<<6 | 0x2A)")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(verbatim: "Voló en Build 16: F0 0A 7F 7F BE AA").font(.system(.caption, design: .monospaced))
                }
            }
            .navigationTitle("Pruebas")
        }
    }
}

// =====================================================================
// MARK: - TAB CONSOLA
// =====================================================================
struct ConsolaView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(verbatim: "Registro en vivo")) {
                    TextEditor(text: $pilot.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 380)
                    HStack {
                        Button(action: {
                            UIPasteboard.general.string = pilot.log
                            pilot.agregarLog("Copiado al portapapeles.")
                        }) { Text(verbatim: "Copiar registro") }
                        Spacer()
                        Button(action: { pilot.log = "" }) { Text(verbatim: "Limpiar").foregroundColor(.red) }
                    }
                }
            }
            .navigationTitle("Consola")
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
