import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI MASTER v4 — MANDO DEFINITIVO SILVERLIT / WECCAN PARA iOS
// =====================================================================

struct ByteField {
    let desc: String
    let index: Int
    let shift: Int
    let mask: UInt8
    let max: Int
    let mid: Int
}

struct ProtoProfile: Identifiable {
    let id = UUID()
    let name: String
    let byteTotal: Int
    let headerByte: UInt8?
    let reverse: Bool
    let fields: [ByteField]

    func field(contiene: String) -> ByteField? {
        fields.first { $0.desc.lowercased().contains(contiene) }
    }

    func build(gas: Int? = nil, pitch: Int? = nil, yaw: Int? = nil,
               trim: Int? = nil, luz: Int? = nil, match: Int? = nil) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: byteTotal)
        if let h = headerByte { out[0] = h }
        
        var vals: [(String, Int)] = []
        if let v = match { vals.append(("match", v)) }
        if let v = gas { vals.append(("rotor", v)) }
        if let v = pitch { vals.append(("pitch", v)) }
        if let v = yaw { vals.append(("yaw", v)) }
        if let v = trim { vals.append(("trim", v)) }
        if let v = luz { vals.append(("light", v)) }

        for (canal, valor) in vals {
            guard let f = field(contiene: canal) else { continue }
            let clamped = Swift.max(0, Swift.min(f.max, valor))
            let bits = (UInt8(clamped) << f.shift) & f.mask
            out[f.index] |= bits
        }
        return out
    }

    var resumen: String {
        "\(byteTotal) bytes · header: \(headerByte.map { String(format: "0x%02X", $0) } ?? "none") · campos: \(fields.map(\.desc).joined(separator: ", "))"
    }
}

enum Perfiles {
    static let silverlitHeli = ProtoProfile(
        name: "Silverlit Helicopter (APPS_airplane) — OFICIAL",
        byteTotal: 5, headerByte: 0x78, reverse: false,
        fields: [
            ByteField(desc: "matchByte", index: 0, shift: 6, mask: 0xC0, max: 3, mid: 1),
            ByteField(desc: "rotorByte", index: 1, shift: 0, mask: 0x7F, max: 128, mid: 64),
            ByteField(desc: "pitchByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "trimerByte", index: 4, shift: 0, mask: 0x0F, max: 15, mid: 8),
            ByteField(desc: "lightByte", index: 4, shift: 4, mask: 0xF0, max: 7, mid: 3),
        ])

    static let btferrari = ProtoProfile(
        name: "Silverlit BTFerrari (APPS_Car)",
        byteTotal: 5, headerByte: 0x72, reverse: true,
        fields: [
            ByteField(desc: "matchByte", index: 4, shift: 6, mask: 0xC0, max: 3, mid: 1),
            ByteField(desc: "rotorByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 1, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "trimerByte", index: 0, shift: 0, mask: 0x0F, max: 15, mid: 7),
            ByteField(desc: "lightByte", index: 0, shift: 4, mask: 0xF0, max: 15, mid: 7),
        ])

    static let weccanI737 = ProtoProfile(
        name: "WeCCAN i737 (6B)",
        byteTotal: 6, headerByte: nil, reverse: true,
        fields: [
            ByteField(desc: "unknownByte", index: 0, shift: 0, mask: 0x0F, max: 15, mid: 8),
            ByteField(desc: "fightByte", index: 0, shift: 4, mask: 0xF0, max: 15, mid: 8),
            ByteField(desc: "trimerByte", index: 1, shift: 0, mask: 0xFF, max: 32, mid: 16),
            ByteField(desc: "yawByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "rotorByte", index: 4, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "matchByte", index: 5, shift: 6, mask: 0xC0, max: 3, mid: 2),
        ])

    static let todos = [silverlitHeli, btferrari, weccanI737]
}

// MARK: - Gestor de Comunicación MFi (ExternalAccessory)

final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var accesorios: [AccInfo] = []
    @Published var conectado = false
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0

    struct AccInfo: Identifiable, Hashable {
        let id: Int
        let nombre: String
        let fabricante: String
        let protocolos: [String]
    }

    private var session: EASession?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidConnect(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidDisconnect(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)
    }

    @objc private func accessoryDidConnect(_ notification: Notification) {
        agregarLog("NOTIF: Accesorio MFi conectado a iOS!")
        _ = escanear { self.agregarLog($0) }
    }

    @objc private func accessoryDidDisconnect(_ notification: Notification) {
        agregarLog("NOTIF: Accesorio MFi desconectado de iOS.")
        cerrar()
        _ = escanear { self.agregarLog($0) }
    }

    func mostrarPickeriOS(loguear: @escaping (String) -> Void) {
        loguear("Abriendo selector nativo de accesorios MFi de iOS...")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withPredicate: nil, completion: nil)
    }

    func escanear(loguear: (String) -> Void) -> [AccInfo] {
        let lista = EAAccessoryManager.shared().connectedAccessories.map { acc in
            AccInfo(id: acc.connectionID, nombre: acc.name, fabricante: acc.manufacturer,
                    protocolos: acc.protocolStrings)
        }
        accesorios = lista
        if lista.isEmpty {
            loguear("SCAN: No se detectan accesorios MFi conectados aún.")
        } else {
            for a in lista {
                loguear("SCAN: Detectado \(a.nombre) [\(a.fabricante)] -> Protocolos: \(a.protocolos.joined(separator: ", "))")
            }
        }
        return lista
    }

    func autoConectar(loguear: @escaping (String) -> Void) -> Bool {
        let lista = escanear(loguear: loguear)
        guard let heli = lista.first(where: { $0.nombre.lowercased().contains("heli") || $0.nombre.lowercased().contains("silverlit") }) ?? lista.first else {
            loguear("AUTO: Sin accesorios para conectar.")
            return false
        }
        guard let proto = heli.protocolos.first else {
            loguear("AUTO: El accesorio no tiene protocolo expuesto.")
            return false
        }
        return conectar(acc: heli, proto: proto, loguear: loguear)
    }

    func conectar(acc: AccInfo, proto: String, loguear: @escaping (String) -> Void) -> Bool {
        cerrar(loguear: loguear)
        guard let ea = EAAccessoryManager.shared().connectedAccessories.first(where: { $0.connectionID == acc.id }) else {
            loguear("CONN: Error, el accesorio no está conectado en iOS.")
            return false
        }
        guard let ses = EASession(accessory: ea, forProtocol: proto) else {
            loguear("CONN: iOS rechazó EASession para protocolo '\(proto)'.")
            return false
        }
        session = ses
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
        loguear("¡CONECTADO con éxito a \(acc.nombre) [\(proto)]!")
        return true
    }

    func cerrar(loguear: (String) -> Void = { _ in }) {
        if let ses = session {
            ses.inputStream?.close()
            ses.outputStream?.close()
            ses.inputStream?.remove(from: .main, forMode: .default)
            ses.outputStream?.remove(from: .main, forMode: .default)
            loguear("Sesión cerrada.")
        }
        session = nil
        conectado = false
        framesEnviados = 0
    }

    func enviar(_ bytes: [UInt8], loguear: @escaping (String) -> Void) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else {
            return false
        }
        let ok = out.write(bytes, maxLength: bytes.count) == bytes.count
        if ok {
            framesEnviados += 1
        }
        return ok
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred:
            DispatchQueue.main.async { self.agregarLog("STREAM: Error en comunicación.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Conexión finalizada por el helicóptero.")
                self.conectado = false
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

    @State private var accSel: HeliManager.AccInfo?
    @State private var protoSel = ""
    @State private var perfiles: [ProtoProfile] = Perfiles.todos
    @State private var perfilIdx = 0

    // Mandos
    @State private var gas: Double = 64
    @State private var pitch: Double = 127
    @State private var yaw: Double = 127
    @State private var trim: Int = 8
    @State private var matchVal: Int = 1
    @State private var luces = false
    @State private var vivo = false
    @State private var hz = 20.0
    @State private var capSeguro = true
    @State private var testeando = false

    var perfil: ProtoProfile { perfiles[perfilIdx] }

    var tramaActual: [UInt8] {
        var g: Int = Int(gas)
        if capSeguro { g = Swift.min(g, 80) }
        let luzVal = luces ? 7 : 3
        return perfil.build(gas: g, pitch: Int(pitch), yaw: Int(yaw),
                            trim: trim, luz: luzVal, match: matchVal)
    }

    var body: some View {
        TabView {
            mandoTab.tabItem { Label("Mando", systemImage: "gamecontroller.fill") }
            testsTab.tabItem { Label("Tests", systemImage: "bolt.horizontal.fill") }
            logTab.tabItem { Label("Log", systemImage: "terminal.fill") }
        }
        .onAppear {
            mgr.agregarLog("BluHeli Master v4 Iniciado. Escaneando...")
            _ = mgr.autoConectar(loguear: { mgr.agregarLog($0) })
        }
    }

    // ---------- TAB 1: MANDO ----------
    var mandoTab: some View {
        NavigationView {
            Form {
                Section("Estado de Conexión") {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 12, height: 12)
                        Text(mgr.conectado ? "CONECTADO [\(mgr.protoActivo)]" : "DESCONECTADO").bold()
                        Spacer()
                        Text("\(mgr.framesEnviados) tramas").font(.caption).foregroundColor(.secondary)
                    }
                    
                    if !mgr.conectado {
                        Button(action: {
                            _ = mgr.autoConectar(loguear: { mgr.agregarLog($0) })
                        }) {
                            Label("Reconectar Helicóptero", systemImage: "arrow.clockwise")
                        }
                        
                        Button(action: {
                            mgr.mostrarPickeriOS(loguear: { mgr.agregarLog($0) })
                        }) {
                            Label("Abrir Selector Bluetooth MFi", systemImage: "wave.3.forward.circle")
                        }
                    } else {
                        Button("Desconectar") {
                            mgr.cerrar(loguear: { mgr.agregarLog($0) })
                        }.foregroundColor(.red)
                    }
                }

                Section("Perfil de Vuelo") {
                    Picker("Perfil", selection: $perfilIdx) {
                        ForEach(Array(perfiles.enumerated()), id: \.offset) { i, p in
                            Text(p.name).tag(i)
                        }
                    }
                }

                Section("Controles de Vuelo") {
                    Toggle("🛡 Modo Seguro (Gas máx 80)", isOn: $capSeguro).tint(.orange)
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("GAS (Rotor)").bold()
                            Spacer()
                            Text("\(Int(capSeguro ? Swift.min(gas, 80) : gas))").font(.headline).foregroundColor(gas > 64 ? .orange : .green)
                        }
                        Slider(value: $gas, in: 64...128, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Adelante/Atrás)").bold()
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
                            ForEach(0..<16) { Text("\($0)").tag($0) }
                        }.pickerStyle(.menu)
                        
                        Picker("Match", selection: $matchVal) {
                            ForEach(0..<4) { Text("m\($0)").tag($0) }
                        }.pickerStyle(.menu)
                        
                        Toggle("Luces", isOn: $luces).tint(.yellow)
                    }

                    HStack {
                        Toggle(vivo ? "TRANSMITIENDO" : "Enviar Continuo", isOn: $vivo)
                            .tint(vivo ? .green : .blue)
                    }

                    HStack {
                        Button("🛑 STOP") {
                            gas = 64; pitch = 127; yaw = 127
                            _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: trim, luz: 3, match: matchVal), loguear: { mgr.agregarLog($0) })
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        
                        Spacer()
                        
                        Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("BluHeli Mando")
            .onChange(of: vivo) { on in
                guard on else { return }
                Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { t in
                    if !vivo || !mgr.conectado { t.invalidate(); vivo = false; return }
                    _ = mgr.enviar(tramaActual, loguear: { mgr.agregarLog($0) })
                }
            }
        }
    }

    // ---------- TAB 2: TESTS ----------
    var testsTab: some View {
        NavigationView {
            Form {
                Section("Suite de Diagnóstico Rápido") {
                    Button("💡 Test Luces x3") { probarLuces() }
                    Button("⚡ Pulso Gas Suave (76 - 1.5s)") { pulsarGas(76, duracion: 1.5) }
                    Button("🔄 Barrido Match (0..3)") { barridoMatch() }
                    Button("🎯 Centrar Mandos") { gas = 64; pitch = 127; yaw = 127 }
                }
            }
            .navigationTitle("Diagnóstico")
        }
    }

    // ---------- TAB 3: LOG ----------
    var logTab: some View {
        NavigationView {
            Form {
                Section("Registro de Eventos") {
                    TextEditor(text: $mgr.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Log") {
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

    func pulsarGas(_ g: Int, duracion: Double) {
        testeando = true
        mgr.agregarLog("TEST: Pulso gas \(g) por \(duracion)s...")
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            n += 1
            _ = mgr.enviar(perfil.build(gas: g, pitch: 127, yaw: 127, trim: 8, luz: 3, match: matchVal), loguear: { mgr.agregarLog($0) })
            if n >= Int(duracion * 20) {
                t.invalidate()
                _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: 8, luz: 3, match: matchVal), loguear: { mgr.agregarLog($0) })
                testeando = false
                mgr.agregarLog("TEST: Gas finalizado.")
            }
        }
    }

    func probarLuces() {
        testeando = true
        mgr.agregarLog("TEST: Luces ON/OFF x3...")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { t in
            paso += 1
            let on = (paso % 2 == 1)
            let luzVal = on ? 7 : 3
            _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: 8, luz: luzVal, match: matchVal), loguear: { mgr.agregarLog($0) })
            if paso >= 6 {
                t.invalidate()
                testeando = false
                mgr.agregarLog("TEST: Luces finalizado.")
            }
        }
    }

    func barridoMatch() {
        testeando = true
        mgr.agregarLog("TEST: Barrido match 0..3...")
        var m = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            defer { m += 1 }
            if m > 3 {
                t.invalidate()
                testeando = false
                mgr.agregarLog("TEST: Barrido match terminado.")
                return
            }
            mgr.agregarLog("Probando MATCH = \(m)...")
            _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: 8, luz: 7, match: m), loguear: { mgr.agregarLog($0) })
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
