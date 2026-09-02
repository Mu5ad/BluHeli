import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI PILOT MASTER v9 — SISTEMA DE VUELO WECCAN (6 BYTES) CONFIRMADO
// =====================================================================

final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0

    private var session: EASession?
    private var timerAutoConnect: Timer?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryConnected(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDisconnected(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)

        // Búsqueda continua de reconexión cada 1.2s
        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
    }

    @objc private func accessoryConnected(_ notification: Notification) {
        agregarLog("NOTIF: Helicóptero reconectado.")
        buscarYConectarAuto()
    }

    @objc private func accessoryDisconnected(_ notification: Notification) {
        agregarLog("NOTIF: Helicóptero desconectado.")
        cerrar()
    }

    func buscarYConectarAuto() {
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty { return }

        for acc in accesorios {
            let candidatos = ["com.silverlit.datapath", "com.issc.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
            for proto in candidatos {
                if acc.protocolStrings.contains(proto) {
                    if conectar(acc: acc, proto: proto) { return }
                }
            }
            if let primer = acc.protocolStrings.first {
                if conectar(acc: acc, proto: primer) { return }
            }
        }
    }

    func conectar(acc: EAAccessory, proto: String) -> Bool {
        cerrar()
        agregarLog("Conectando con \(acc.name)...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error al abrir enlace MFi con '\(proto)'.")
            return false
        }

        session = ses
        nombreDispositivo = acc.name
        protoActivo = proto

        if let inp = ses.inputStream {
            inp.delegate = self
            inp.schedule(in: .main, forMode: .default)
            inp.open()
        }
        if let out = ses.outputStream {
            out.delegate = self
            out.schedule(in: .main, forMode: .default)
            out.open()
        }

        conectado = true
        agregarLog(">>> ¡CONECTADO CON ÉXITO A \(acc.name)! <<<")
        return true
    }

    func cerrar() {
        if let ses = session {
            ses.inputStream?.close()
            ses.outputStream?.close()
            ses.inputStream?.remove(from: .main, forMode: .default)
            ses.outputStream?.remove(from: .main, forMode: .default)
        }
        session = nil
        conectado = false
        nombreDispositivo = ""
        protoActivo = ""
    }

    func enviarTrama(_ bytes: [UInt8]) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else { return false }
        let n = out.write(bytes, maxLength: bytes.count)
        if n == bytes.count {
            framesEnviados += 1
            return true
        }
        return false
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred:
            DispatchQueue.main.async { self.agregarLog("STREAM: Error.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Desconexión.")
                self.cerrar()
            }
        default: break
        }
    }

    func agregarLog(_ s: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        log = "[\(df.string(from: Date()))] \(s)\n" + log
        if log.count > 15000 { log = String(log.prefix(15000)) }
    }
}

// MARK: - Vista de Vuelo Principal
struct ContentView: View {
    @StateObject private var mgr = HeliManager()

    // Configuración verificada que hizo volar el helicóptero:
    // Canal C (Azul = Match 2), Protocolo Weccan 6-Bytes
    @AppStorage("canalSeleccionado") private var canalSeleccionado = 2 // Canal C (Azul)
    @AppStorage("calibracionGuardada") private var calibracionGuardada = true

    // Mandos de Vuelo Proporcionales (0..100%)
    @State private var porcentajeGas: Double = 0.0  // 0% a 100%
    @State private var pitch: Double = 127.0        // 0..255 (127 neutro)
    @State private var yaw: Double = 127.0          // 0..255 (127 neutro)
    @State private var trim: Int = 16               // 0..32 (16 neutro de i737)
    @State private var luces = true
    @State private var limiteSeguridad = true       // Limita a 65% para que no se estampe contra el techo
    @State private var maniobraEnCurso = false

    // Generador de Trama Weccan 6-Bytes Verificada
    func construirTramaWeccan(gasPct: Double, pitchVal: Double, yawVal: Double, trimVal: Int, luzVal: Bool, match: Int) -> [UInt8] {
        let b0: UInt8 = luzVal ? 0xF0 : 0x00
        let t = UInt8(Swift.max(0, Swift.min(32, trimVal)))
        let y = UInt8(Swift.max(0, Swift.min(255, Int(yawVal))))
        let p = UInt8(Swift.max(0, Swift.min(255, Int(pitchVal))))
        
        // Mapeo suave de potencia del rotor (0..255):
        // Con límite de seguridad: máximo 140 de 255 (~55% de empuje) para vuelo suave en salón
        let maxPotencia = limiteSeguridad ? 140.0 : 220.0
        let rotorPotencia = gasPct > 0 ? (gasPct / 100.0) * maxPotencia : 0.0
        let g = UInt8(Swift.max(0, Swift.min(255, Int(rotorPotencia))))
        
        // Flags: Match en bits 6..7, 0x2A en bits 0..5
        let flags = UInt8(((match & 3) << 6) | 0x2A)
        return [b0, t, y, p, g, flags]
    }

    var tramaActual: [UInt8] {
        construirTramaWeccan(gasPct: porcentajeGas, pitchVal: pitch, yawVal: yaw,
                             trimVal: trim, luzVal: luces, match: canalSeleccionado)
    }

    var body: some View {
        TabView {
            cockpitTab.tabItem {
                Label("Cabina", systemImage: "airplane.circle.fill")
            }

            ajustesTab.tabItem {
                Label("Ajustes", systemImage: "gearshape.fill")
            }

            consolaTab.tabItem {
                Label("Consola", systemImage: "terminal.fill")
            }
        }
        .onAppear {
            mgr.agregarLog("BluHeli Pilot Iniciado. Conectando por Canal C (Azul)...")
            mgr.buscarYConectarAuto()
            iniciarBucleTransmisionConstante()
        }
    }

    // =================================================================
    // TAB 1: CABINA DE VUELO (COCKPIT)
    // =================================================================
    var cockpitTab: some View {
        NavigationView {
            Form {
                // Estado del enlace
                Section {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(mgr.conectado ? "CONECTADO A SL_BLUTECH" : "BUSCANDO HELICÓPTERO...").bold()
                            Text("Protocolo: Weccan 6B (Verificado) · Canal C (Azul)").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(mgr.framesEnviados) tx").font(.caption).foregroundColor(.secondary)
                    }
                }

                // Control del Acelerador
                Section(header: Text("ACELERADOR PRINCIPAL (GAS)").bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("POTENCIA").bold()
                            Spacer()
                            Text("\(Int(porcentajeGas))%")
                                .font(.title2)
                                .bold()
                                .foregroundColor(porcentajeGas > 0 ? (porcentajeGas > 60 ? .orange : .green) : .secondary)
                        }

                        Slider(value: $porcentajeGas, in: 0...100, step: 1)
                            .tint(porcentajeGas > 0 ? .green : .gray)

                        Toggle("🛡 Modo Interior / Techo (Potencia máx 60%)", isOn: $limiteSeguridad)
                            .tint(.orange)
                            .font(.footnote)
                    }

                    // Botones de Despegue y Aterrizaje Asistido
                    HStack(spacing: 12) {
                        Button(action: { despegueSuaveAutomatico() }) {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                                Text("DESPEGAR (Hover 45%)").bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(maniobraEnCurso || !mgr.conectado)

                        Button(action: { aterrizajeSuaveAutomatico() }) {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                Text("ATERRIZAR").bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .disabled(porcentajeGas == 0 || maniobraEnCurso)
                    }
                    .padding(.vertical, 4)
                }

                // Mandos de Dirección y Estabilidad
                Section(header: Text("DIRECCIÓN Y ESTABILIZACIÓN").bold()) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Adelante / Atrás)").bold()
                            Spacer()
                            Text("\(Int(pitch))").font(.caption)
                        }
                        Slider(value: $pitch, in: 0...255, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("YAW (Giro Izquierda / Derecha)").bold()
                            Spacer()
                            Text("\(Int(yaw))").font(.caption)
                        }
                        Slider(value: $yaw, in: 0...255, step: 1)
                    }

                    HStack {
                        Picker("Trim (Estabilizador)", selection: $trim) {
                            ForEach(0..<33) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Toggle("Faros LED", isOn: $luces).tint(.yellow)
                    }

                    Button("🎯 Centrar Dirección y Timón") {
                        pitch = 127.0
                        yaw = 127.0
                        trim = 16
                    }
                    .font(.footnote)
                }

                // Botón Rojo de Parada de Emergencia
                Section {
                    Button(action: { paradaEmergenciaInmediata() }) {
                        HStack {
                            Spacer()
                            Image(systemName: "stop.circle.fill").font(.title3)
                            Text("CORTE DE MOTOR INMEDIATO (STOP)").font(.headline).bold()
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                // Telemetría en vivo
                Section {
                    HStack {
                        Text("TRAMA EN VIVO:")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("BluHeli Cockpit")
        }
    }

    // =================================================================
    // TAB 2: AJUSTES & CANALES
    // =================================================================
    var ajustesTab: some View {
        NavigationView {
            Form {
                Section("Canal de Vuelo") {
                    Picker("Banda Sintonizada", selection: $canalSeleccionado) {
                        Text("🔴 Canal A (Rojo)").tag(0)
                        Text("🟢 Canal B (Verde)").tag(1)
                        Text("🔵 Canal C (Azul - VERIFICADO)").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Tu helicóptero respondió con el Canal C (LED Azul).").font(.caption).foregroundColor(.secondary)
                }

                Section("Prueba Rápida de Motores (2 Segundos)") {
                    Button("⚡ Pulso de Prueba al 35% de Gas (En Mano)") {
                        pulsoPruebaSeguro(35.0)
                    }
                    Button("⚡ Pulso de Prueba al 50% de Gas (En Mano)") {
                        pulsoPruebaSeguro(50.0)
                    }
                }

                Section("Acciones de Seguridad") {
                    Button("🛑 Corte de Motor (Gas a 0)") {
                        paradaEmergenciaInmediata()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    // =================================================================
    // TAB 3: CONSOLA
    // =================================================================
    var consolaTab: some View {
        NavigationView {
            Form {
                Section("Registro de Enlace") {
                    TextEditor(text: $mgr.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Registro") {
                            UIPasteboard.general.string = mgr.log
                            mgr.agregarLog("Copiado al portapapeles.")
                        }
                        Spacer()
                        Button("Limpiar") { mgr.log = "" }.foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Consola")
        }
    }

    // =================================================================
    // MOTOR DE CONTROL Y SEGURIDAD
    // =================================================================

    // Transmisión continua a 20 Hz constante SIEMPRE para que el heli NUNCA quede colgado acelerando
    func iniciarBucleTransmisionConstante() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if mgr.conectado {
                _ = mgr.enviarTrama(tramaActual)
            }
        }
    }

    func despegueSuaveAutomatico() {
        maniobraEnCurso = true
        mgr.agregarLog("Iniciando despegue suave...")
        porcentajeGas = 0.0
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            paso += 1
            porcentajeGas = Swift.min(48.0, Double(paso * 4))
            if porcentajeGas >= 48.0 {
                t.invalidate()
                maniobraEnCurso = false
                mgr.agregarLog("Despegue estabilizado a 48% (Hover).")
            }
        }
    }

    func aterrizajeSuaveAutomatico() {
        maniobraEnCurso = true
        mgr.agregarLog("Iniciando aterrizaje suave...")
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            porcentajeGas = Swift.max(0.0, porcentajeGas - 3.0)
            if porcentajeGas <= 0.0 {
                t.invalidate()
                porcentajeGas = 0.0
                maniobraEnCurso = false
                mgr.agregarLog("Aterrizado. Motor detenido.")
            }
        }
    }

    func paradaEmergenciaInmediata() {
        maniobraEnCurso = false
        porcentajeGas = 0.0
        pitch = 127.0
        yaw = 127.0
        // Enviar ráfaga inmediata de tramas a Gas = 0
        for _ in 0..<10 {
            _ = mgr.enviarTrama(construirTramaWeccan(gasPct: 0, pitchVal: 127, yawVal: 127, trimVal: trim, luzVal: luces, match: canalSeleccionado))
        }
        mgr.agregarLog("🛑 PARADA DE EMERGENCIA: Motor cortado a 0%.")
    }

    func pulsoPruebaSeguro(_ potencia: Double) {
        maniobraEnCurso = true
        mgr.agregarLog("Prueba segura a \(Int(potencia))% de potencia por 2s...")
        porcentajeGas = potencia
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.porcentajeGas = 0.0
            self.maniobraEnCurso = false
            self.mgr.agregarLog("Fin de prueba. Motor a 0%.")
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
