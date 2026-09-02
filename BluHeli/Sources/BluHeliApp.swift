import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLU-TECH HELI v5 (OFFICIAL PROTOCOL DATA & AUTHENTIC MFi STRINGS)
// =====================================================================

final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0
    @Published var bateriaInfo = "OK"

    private var session: EASession?
    private var timerAutoConnect: Timer?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryConnected(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDisconnected(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)
        
        // Iniciar timer de auto-búsqueda cada 1.5s
        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
    }

    @objc private func accessoryConnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Accesorio Bluetooth MFi conectado!")
        buscarYConectarAuto()
    }

    @objc private func accessoryDisconnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Accesorio desconectado.")
        cerrar()
    }

    func abrirSelectorBluetooth() {
        agregarLog("Abriendo selector Bluetooth MFi de iOS...")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil, completion: nil)
    }

    func buscarYConectarAuto() {
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty {
            return
        }

        for acc in accesorios {
            agregarLog("Detectado: \(acc.name) [\(acc.manufacturer)] - Protocolos: \(acc.protocolStrings.joined(separator: ", "))")
            
            // Prioridad: com.issc.datapath o com.silverlit.datapath
            let candidatos = ["com.issc.datapath", "com.silverlit.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
            for proto in candidatos {
                if acc.protocolStrings.contains(proto) {
                    if conectar(acc: acc, proto: proto) {
                        return
                    }
                }
            }
            
            // Si tiene cualquier otro protocolo anunciado
            if let primerProto = acc.protocolStrings.first {
                if conectar(acc: acc, proto: primerProto) {
                    return
                }
            }
        }
    }

    func conectar(acc: EAAccessory, proto: String) -> Bool {
        cerrar()
        agregarLog("Intentando abrir EASession con \(acc.name) [\(proto)]...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error: iOS rechazó EASession para '\(proto)'.")
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
        guard let out = session?.outputStream, out.hasSpaceAvailable else {
            return false
        }
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
            DispatchQueue.main.async { self.agregarLog("STREAM: Error de enlace.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Enlace cerrado por el helicóptero.")
                self.cerrar()
            }
        case .hasBytesAvailable:
            if let inp = aStream as? InputStream {
                var buf = [UInt8](repeating: 0, count: 64)
                let n = inp.read(&buf, maxLength: 64)
                if n > 0 {
                    let hex = buf.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")
                    DispatchQueue.main.async { self.agregarLog("RX Heli: \(hex)") }
                }
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

// MARK: - Vista Principal

struct ContentView: View {
    @StateObject private var mgr = HeliManager()

    // Mandos de vuelo
    @State private var gas: Double = 64
    @State private var pitch: Double = 127
    @State private var yaw: Double = 127
    @State private var trim: Int = 10     // default 10 de protocalData.plist
    @State private var matchVal: Int = 1
    @State private var luces = true       // Luces encendidas por defecto
    @State private var transmitiendo = true
    @State private var capSeguro = true

    // Generador oficial de trama de vuelo (5 bytes)
    // byte 0: 0x78 | ((match & 3) << 6)
    // byte 1: rotor (gas 64..128)
    // byte 2: pitch (0..255)
    // byte 3: yaw (0..255)
    // byte 4: (light << 5) | (trim & 0x1F)
    var tramaActual: [UInt8] {
        let header = UInt8(0x78 | ((matchVal & 3) << 6))
        let effectiveGas = UInt8(capSeguro ? Swift.min(Int(gas), 80) : Int(gas))
        let effectivePitch = UInt8(Swift.max(0, Swift.min(255, Int(pitch))))
        let effectiveYaw = UInt8(Swift.max(0, Swift.min(255, Int(yaw))))
        let lightVal = UInt8(luces ? 7 : 3)
        let byte4 = ((lightVal & 0x07) << 5) | (UInt8(trim) & 0x1F)
        return [header, effectiveGas, effectivePitch, effectiveYaw, byte4]
    }

    var body: some View {
        TabView {
            mandoTab.tabItem { Label("Mando", systemImage: "gamecontroller.fill") }
            testsTab.tabItem { Label("Tests", systemImage: "bolt.horizontal.fill") }
            logTab.tabItem { Label("Consola", systemImage: "terminal.fill") }
        }
        .onAppear {
            mgr.agregarLog("Blu-Tech Heli v5 Iniciado. Buscando SL_BluTechHeli...")
            mgr.buscarYConectarAuto()
            iniciarBucleTransmision()
        }
    }

    // ---------- TAB 1: MANDO ----------
    var mandoTab: some View {
        NavigationView {
            Form {
                Section("Estado de Conexión") {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(mgr.conectado ? "CONECTADO: \(mgr.nombreDispositivo)" : "BUSCANDO HELICÓPTERO...").bold()
                            if mgr.conectado {
                                Text("Protocolo: \(mgr.protoActivo)").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(mgr.framesEnviados) tramas").font(.caption).foregroundColor(.secondary)
                    }

                    if !mgr.conectado {
                        Button(action: { mgr.buscarYConectarAuto() }) {
                            Label("Reconectar Ahora", systemImage: "arrow.clockwise")
                        }
                        Button(action: { mgr.abrirSelectorBluetooth() }) {
                            Label("Abrir Selector Bluetooth MFi", systemImage: "wave.3.forward.circle")
                        }
                    }
                }

                Section("Controles de Vuelo") {
                    Toggle("🛡 Modo Seguro (Gas máx 80)", isOn: $capSeguro).tint(.orange)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("GAS (Acelerador Rotor)").bold()
                            Spacer()
                            Text("\(Int(capSeguro ? Swift.min(gas, 80) : gas))")
                                .font(.headline)
                                .foregroundColor(gas > 64 ? .orange : .green)
                        }
                        Slider(value: $gas, in: 64...128, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Adelante / Atrás)").bold()
                            Spacer()
                            Text("\(Int(pitch))").font(.subheadline)
                        }
                        Slider(value: $pitch, in: 0...255, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("YAW (Giro de Cola)").bold()
                            Spacer()
                            Text("\(Int(yaw))").font(.subheadline)
                        }
                        Slider(value: $yaw, in: 0...255, step: 1)
                    }

                    HStack {
                        Picker("Trim", selection: $trim) {
                            ForEach(0..<21) { Text("\($0)").tag($0) }
                        }.pickerStyle(.menu)

                        Picker("Match", selection: $matchVal) {
                            ForEach(0..<4) { Text("m\($0)").tag($0) }
                        }.pickerStyle(.menu)

                        Toggle("Luces", isOn: $luces).tint(.yellow)
                    }

                    HStack {
                        Button("🛑 PARADA DE EMERGENCIA") {
                            gas = 64
                            pitch = 127
                            yaw = 127
                            _ = mgr.enviarTrama(tramaActual)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Spacer()

                        Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Blu-Tech Heli")
        }
    }

    // ---------- TAB 2: TESTS ----------
    var testsTab: some View {
        NavigationView {
            Form {
                Section("Pruebas Rápidas de Diagnóstico") {
                    Button("💡 Test Luces x3") { testLuces() }
                    Button("⚡ Pulso Gas Suave (76 - 1.5s)") { testGas(76, duracion: 1.5) }
                    Button("🔄 Barrido Match (0..3)") { testMatchSweep() }
                    Button("🎯 Centrar Mandos") { gas = 64; pitch = 127; yaw = 127 }
                }
            }
            .navigationTitle("Pruebas")
        }
    }

    // ---------- TAB 3: LOG ----------
    var logTab: some View {
        NavigationView {
            Form {
                Section("Registro en Vivo") {
                    TextEditor(text: $mgr.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Registro") {
                            UIPasteboard.general.string = mgr.log
                            mgr.agregarLog("Log copiado al portapapeles.")
                        }
                        Spacer()
                        Button("Limpiar") { mgr.log = "" }.foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Consola")
        }
    }

    func iniciarBucleTransmision() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if mgr.conectado && transmitiendo {
                _ = mgr.enviarTrama(tramaActual)
            }
        }
    }

    func testGas(_ g: Int, duracion: Double) {
        mgr.agregarLog("TEST: Pulso de gas \(g) por \(duracion)s...")
        let oldGas = gas
        gas = Double(g)
        DispatchQueue.main.asyncAfter(deadline: .now() + duracion) {
            self.gas = oldGas
            self.mgr.agregarLog("TEST: Fin de pulso de gas.")
        }
    }

    func testLuces() {
        mgr.agregarLog("TEST: Parpadeo de luces x3...")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { t in
            paso += 1
            self.luces.toggle()
            if paso >= 6 {
                t.invalidate()
                self.luces = true
                self.mgr.agregarLog("TEST: Fin de test de luces.")
            }
        }
    }

    func testMatchSweep() {
        mgr.agregarLog("TEST: Probando Match 0, 1, 2, 3...")
        var m = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            defer { m += 1 }
            if m > 3 {
                t.invalidate()
                self.matchVal = 1
                self.mgr.agregarLog("TEST: Fin de barrido match.")
                return
            }
            self.matchVal = m
            self.mgr.agregarLog("Probando MATCH = \(m)...")
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
