import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI PILOT v13 — PROTOCOLO REAL (TEXTO HEX) + HILO DE ENLACE + MANDOS
//
// Ingeniería inversa del binario oficial sHelicopter (XPGMobileAppConvertor):
//   convertToAppProtocolData:  acumula cada campo del plist con
//                              valor << beginBit en un entero de 64 bits.
//   convertToString:andCommandNum:  "%llx" rellenado con "00" hasta 5 bytes,
//                              protocolHead "x" delante, dataUsingEncoding:UTF8.
//   => LA TRAMA ES TEXTO ASCII: "x" + 10 dígitos hex en minúsculas.
//   Campos (protocalData.plist):  trimmer bits 0-4 (0..20, mid 10)
//                                 light   bits 5-7 (mid 4)
//                                 yaw     bits 8-15 (0..255, mid 127)
//                                 pitch   bits 16-23 (0..255, mid 127)
//                                 rotor   bits 24-31 (0..128)
//                                 btMatch bits 38-39 (0..3)
//   Ejemplo neutro gas 0, canal B: "x40007f7f8a"
//   Envío periódico: 0,05 s (20 Hz). Respuesta: 4 dígitos hex en texto,
//   bits 2-3 = batería (receive_power), bits 4-5 = emergencia.
//
// Todo lo enviado en builds anteriores eran bytes binarios: basura para este
// parser (de ahí LEDs y un despegue caótico que no respondía a gas 0).
// =====================================================================

// MARK: - Perfiles de protocolo

enum Layout: String, Codable, CaseIterable {
    case silverlit   // plist iOS oficial (5 bytes de datos)
    case weccan      // weccan_protocal.xml i737 (6 bytes de datos)
}

struct Perfil: Codable, Equatable, Identifiable {
    var id: String
    var nombre: String
    var descripcion: String
    var texto: Bool             // true = ASCII hex ("x" + dígitos); false = binario crudo
    var layout: Layout
    var cabecera: String        // "x", "0x", ""
    var mayusculas: Bool
    var terminador: String      // "", "\r", "\n", "\r\n"
    var checksum: Bool          // añade byte -(suma) al final
    var rotorMax: Int           // 128 (Silverlit) o 255 (WeCCAN)
    var luz: Int                // silverlit 0..7 (mid 4) · weccan nibble 0..15
    var nibbleBajo: Int         // weccan byte0 bits 0-3 (unknownByte, mid 8)
    var trimMax: Int            // 20 (silverlit) · 32 (weccan)
    var trimNeutro: Int
    var flagsFijos: Int?        // weccan: nil = calculados (0/1/3 según mid) · p.ej. 0x2A
    var ordenInverso: Bool      // binario: emitir byte de índice alto primero

    static let silverlitTexto = Perfil(
        id: "silverlit_texto", nombre: "Silverlit oficial (texto hex)",
        descripcion: "\"x\" + 10 dígitos hex. Exactamente lo que genera la app oficial de 2011.",
        texto: true, layout: .silverlit, cabecera: "x", mayusculas: false, terminador: "",
        checksum: false, rotorMax: 128, luz: 4, nibbleBajo: 0, trimMax: 20, trimNeutro: 10,
        flagsFijos: nil, ordenInverso: false)

    static let weccanTexto = Perfil(
        id: "weccan_texto", nombre: "WeCCAN i737 (texto hex)",
        descripcion: "\"0x\" + 12 dígitos hex según weccan_protocal.xml (misma librería XPG).",
        texto: true, layout: .weccan, cabecera: "0x", mayusculas: false, terminador: "",
        checksum: false, rotorMax: 255, luz: 8, nibbleBajo: 8, trimMax: 32, trimNeutro: 16,
        flagsFijos: nil, ordenInverso: false)

    static let silverlitMayus = Perfil(
        id: "silverlit_mayus", nombre: "Silverlit texto MAYÚSCULAS",
        descripcion: "Igual que el oficial pero con dígitos A-F en mayúsculas.",
        texto: true, layout: .silverlit, cabecera: "x", mayusculas: true, terminador: "",
        checksum: false, rotorMax: 128, luz: 4, nibbleBajo: 0, trimMax: 20, trimNeutro: 10,
        flagsFijos: nil, ordenInverso: false)

    static let silverlitTextoChk = Perfil(
        id: "silverlit_texto_chk", nombre: "Silverlit texto + checksum",
        descripcion: "\"x\" + 12 dígitos: datos y byte de checksum complemento a dos.",
        texto: true, layout: .silverlit, cabecera: "x", mayusculas: false, terminador: "",
        checksum: true, rotorMax: 128, luz: 4, nibbleBajo: 0, trimMax: 20, trimNeutro: 10,
        flagsFijos: nil, ordenInverso: false)

    static let silverlitRaw = Perfil(
        id: "silverlit_raw", nombre: "Silverlit binario 5 bytes",
        descripcion: "[match|0x78, rotor, pitch, yaw, luz|trim] en bytes crudos.",
        texto: false, layout: .silverlit, cabecera: "", mayusculas: false, terminador: "",
        checksum: false, rotorMax: 128, luz: 4, nibbleBajo: 0, trimMax: 20, trimNeutro: 10,
        flagsFijos: nil, ordenInverso: false)

    static let weccanRawBuild16 = Perfil(
        id: "weccan_raw16", nombre: "WeCCAN binario (Build 16)",
        descripcion: "F0 trim yaw pitch gas flags(0x2A|canal). La trama que despegó sin control.",
        texto: false, layout: .weccan, cabecera: "", mayusculas: false, terminador: "",
        checksum: false, rotorMax: 255, luz: 15, nibbleBajo: 0, trimMax: 32, trimNeutro: 10,
        flagsFijos: 0x2A, ordenInverso: false)

    static let candidatos: [Perfil] = [silverlitTexto, weccanTexto, silverlitMayus, silverlitTextoChk, silverlitRaw, weccanRawBuild16]

    var etiquetaFormato: String {
        if texto { return "texto \"\(cabecera)\" + \(layout == .silverlit ? (checksum ? 12 : 10) : (checksum ? 14 : 12)) hex" }
        return "binario \(layout == .silverlit ? 5 : 6)\(checksum ? "+1" : "") bytes"
    }
}

// MARK: - Codificador de tramas

struct Codificador {
    /// Estado de vuelo normalizado: rotor 0..rotorMax, pitch/yaw 0..255, trim 0..trimMax, match 0..3
    static func bytesDatos(perfil p: Perfil, rotor: Int, pitch: Int, yaw: Int, trim: Int, match: Int) -> [UInt8] {
        let r = UInt8(Swift.max(0, Swift.min(p.rotorMax, rotor)))
        let pi = UInt8(Swift.max(0, Swift.min(255, pitch)))
        let ya = UInt8(Swift.max(0, Swift.min(255, yaw)))
        let tr = Swift.max(0, Swift.min(p.trimMax, trim))
        let m = UInt8(match & 3)
        switch p.layout {
        case .silverlit:
            // Orden del entero de 40 bits impreso MSB primero:
            // byte4 = match<<6 (bits 38-39) · byte3 rotor · byte2 pitch · byte1 yaw · byte0 luz<<5 | trim
            let b4: UInt8 = m << 6
            let b0: UInt8 = UInt8((p.luz & 7) << 5) | UInt8(tr & 0x1F)
            return [b4, r, pi, ya, b0]
        case .weccan:
            // Índices XML: 0 luz/unknown · 1 trim · 2 yaw · 3 pitch · 4 rotor · 5 flags
            let i0: UInt8 = UInt8((p.luz & 0xF) << 4) | UInt8(p.nibbleBajo & 0xF)
            let i1: UInt8 = UInt8(tr)
            var flags: UInt8
            if let f = p.flagsFijos {
                flags = UInt8(f & 0x3F)
            } else {
                // XPG: flag = 0 si valor < mid, 1 si igual, 3 si mayor
                func flag(_ v: Int, _ mid: Int) -> UInt8 { v < mid ? 0 : (v > mid ? 3 : 1) }
                flags = flag(tr, p.trimNeutro) | (flag(Int(ya), 127) << 2) | (flag(Int(pi), 127) << 4)
            }
            flags |= m << 6
            // Texto: el entero se imprime MSB primero => índice 5 primero.
            // Binario "Build 16": índice 0 primero (ordenInverso = false).
            let porIndice: [UInt8] = [i0, i1, ya, pi, r, flags]
            if p.texto || p.ordenInverso { return Array(porIndice.reversed()) }
            return porIndice
        }
    }

    static func trama(perfil p: Perfil, rotor: Int, pitch: Int, yaw: Int, trim: Int, match: Int) -> (bytes: [UInt8], visible: String) {
        var datos = bytesDatos(perfil: p, rotor: rotor, pitch: pitch, yaw: yaw, trim: trim, match: match)
        if p.checksum {
            let suma = datos.reduce(0) { $0 + Int($1) }
            datos.append(UInt8((256 - (suma % 256)) & 0xFF))
        }
        if p.texto {
            var hex = datos.map { String(format: "%02x", $0) }.joined()
            if p.mayusculas { hex = hex.uppercased() }
            let s = p.cabecera + hex + p.terminador
            return (Array(s.utf8), s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))
        } else {
            var b = datos
            if p.layout == .silverlit { b[0] = b[0] | 0x78 }   // cabecera 'x' fusionada con match
            return (b, b.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }
}

// MARK: - Piloto

/// Hilo dedicado con su propio RunLoop para los streams MFi y el temporizador de envío.
/// La interfaz (hilo principal) puede congelarse al redibujar; este hilo nunca.
final class HiloEnlace: Thread {
    private let listo = DispatchSemaphore(value: 0)
    override func main() {
        let rl = RunLoop.current
        rl.add(NSMachPort(), forMode: .default)
        listo.signal()
        while !isCancelled {
            _ = rl.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
        }
    }
    func arrancar() { start(); listo.wait() }
}

/// Consigna de vuelo que el hilo principal escribe y el hilo de enlace lee (bajo cerrojo).
struct Consigna {
    var gasObjetivo: Double = 0
    var pitch: Double = 127
    var yaw: Double = 127
    var trim: Int = 10
    var match: Int = 1
    var perfil: Perfil = Perfil.silverlitTexto
    var tope: Double = 65
    var armadoActivo: Bool = true
    var rampa: Double = 2.5
    var ticksArmado: Int = 8
}

final class HeliPilot: NSObject, ObservableObject, StreamDelegate {

    static let versionApp = "Pilot v13"

    // Enlace (publicado en el hilo principal)
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0
    @Published var framesDescartados = 0
    @Published var hzReal = 0
    @Published var tramaVisible = ""
    @Published var rxTexto = ""
    @Published var rxHex = ""
    @Published var rxNivel: Int? = nil          // byte 1 de la respuesta "x NN 00 00" (168 = lleno)
    @Published var rxFlag: Int = 0              // byte 2 de la respuesta (visto 01 alguna vez)
    @Published var reconexionBloqueadaHasta: Date? = nil
    @Published var bateriaReposo: Int? = nil    // % máximo de los últimos 10 s (menos afectado por la carga del motor)
    @Published var minutosRestantes: Int? = nil // estimación hasta el 25 %, con la pendiente de los últimos 2 min
    private var historialBateria: [(Date, Int)] = []

    // Modo fácil (botones de dirección + hover memorizado)
    @Published var modoFacil: Bool { didSet { UserDefaults.standard.set(modoFacil, forKey: "modoFacil") } }
    @Published var gasHover: Double { didSet { UserDefaults.standard.set(gasHover, forKey: "gasHover") } }

    var bateriaPorcentaje: Int? {
        guard let n = rxNivel, n != 255 else { return nil }
        return Swift.max(0, Swift.min(100, Int((Double(n) / 168.0 * 100.0).rounded())))
    }

    // Protocolo
    @Published var perfilActivo: Perfil { didSet { guardarPerfil(); sincronizarConsigna() } }
    @Published var intervaloMs: Int { didSet { UserDefaults.standard.set(intervaloMs, forKey: "intervaloMs"); reinstalarTimer() } }
    @Published var match: Int { didSet { UserDefaults.standard.set(match, forKey: "match"); sincronizarConsigna() } }

    // Vuelo
    @Published var gasObjetivo: Double = 0.0 { didSet { sincronizarConsigna() } }
    @Published var gasEnviado: Double = 0.0
    @Published var pitch: Double = 127.0 { didSet { sincronizarConsigna() } }
    @Published var yaw: Double = 127.0 { didSet { sincronizarConsigna() } }
    @Published var trim: Int { didSet { sincronizarConsigna() } }
    @Published var modoSalon: Bool { didSet { UserDefaults.standard.set(modoSalon, forKey: "modoSalon"); sincronizarConsigna() } }
    @Published var autoCentrar: Bool = true
    @Published var gasSpring: Bool = false
    @Published var sensibilidad: Double = 0.7
    @Published var invertirYaw: Bool = false
    @Published var invertirPitch: Bool = false
    @Published var potenciaMantener: Double = 50
    @Published var potenciaDespegue: Double = 45
    @Published var rampaPorTick: Double = 2.5 { didSet { sincronizarConsigna() } }
    @Published var armadoActivo: Bool = true { didSet { sincronizarConsigna() } }
    @Published var armado = false
    @Published var maniobraActiva = false

    // Asistente
    enum EstadoAsistente: Equatable { case inactivo, probando(Int), pregunta(Int), exito(Int), fracaso }
    @Published var asistente: EstadoAsistente = .inactivo
    @Published var potenciaAsistente: Double = 35
    var perfilEnPrueba: Perfil? = nil { didSet { sincronizarConsigna() } }

    let topeSalon: Double = 65.0
    let ticksArmado = 8
    var topeActual: Double { modoSalon ? topeSalon : 100.0 }
    var perfilEnUso: Perfil { perfilEnPrueba ?? perfilActivo }

    // ---- Compartido entre hilos (bajo cerrojo) ----
    private let cerrojo = NSLock()
    private var consigna = Consigna()
    private var rafagaStop = 0
    private var sesionHilo: EASession? = nil

    // ---- Solo hilo de enlace ----
    private let hilo = HiloEnlace()
    private var timerTx: Timer?
    private var gasEnv: Double = 0
    private var ticksEnCero = 0
    private var armadoInterno = false
    private var contadorHz = 0
    private var tUltimoHz = Date()
    private var tUltimoTick = Date()
    private var tUltimoLogRx = Date(timeIntervalSince1970: 0)
    private var txTotal = 0
    private var txDescartados = 0
    private var ticksDesdePublicacion = 0
    private var rxBuffer: [UInt8] = []

    // ---- Solo hilo principal ----
    private var session: EASession?
    private var timerAuto: Timer?
    private var timerManiobra: Timer?
    private var accesorioActualID: Int = -1

    override init() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: "perfilActivo"), let p = try? JSONDecoder().decode(Perfil.self, from: d) {
            perfilActivo = p
        } else {
            perfilActivo = Perfil.silverlitTexto
        }
        intervaloMs = ud.object(forKey: "intervaloMs") as? Int ?? 50
        match = ud.object(forKey: "match") as? Int ?? 1
        modoSalon = ud.object(forKey: "modoSalon") as? Bool ?? true
        modoFacil = ud.object(forKey: "modoFacil") as? Bool ?? true
        gasHover = ud.object(forKey: "gasHover") as? Double ?? 50
        trim = 10
        super.init()
        trim = perfilActivo.trimNeutro
        sincronizarConsigna()

        hilo.name = "BluHeli.enlace"
        hilo.qualityOfService = .userInteractive
        hilo.arrancar()
        reinstalarTimer()

        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioConectado(_:)), name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioDesconectado(_:)), name: .EAAccessoryDidDisconnect, object: nil)

        let ta = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let hasta = self.reconexionBloqueadaHasta {
                if Date() < hasta { return }
                self.reconexionBloqueadaHasta = nil
                self.agregarLog("Reconexión desbloqueada.")
            }
            if !self.conectado { self.buscarYConectarAuto() }
        }
        RunLoop.main.add(ta, forMode: .common)
        timerAuto = ta
        cargarGrabaciones()
        agregarLog("\(HeliPilot.versionApp) listo. Perfil: \(perfilActivo.nombre). Esperando Chatboard...")
    }

    deinit {
        timerAuto?.invalidate(); timerManiobra?.invalidate()
        hilo.cancel()
    }

    private func guardarPerfil() {
        if let d = try? JSONEncoder().encode(perfilActivo) { UserDefaults.standard.set(d, forKey: "perfilActivo") }
    }

    /// Copia la consigna actual para el hilo de enlace. Llamada en el hilo principal.
    private func sincronizarConsigna() {
        let c = Consigna(gasObjetivo: gasObjetivo, pitch: pitch, yaw: yaw, trim: trim, match: match,
                         perfil: perfilEnUso, tope: topeActual, armadoActivo: armadoActivo,
                         rampa: rampaPorTick, ticksArmado: ticksArmado)
        cerrojo.lock(); consigna = c; cerrojo.unlock()
    }

    private func reinstalarTimer() {
        perform(#selector(instalarTimerEnHilo), on: hilo, with: nil, waitUntilDone: false)
    }

    @objc private func instalarTimerEnHilo() {
        timerTx?.invalidate()
        let ms = Swift.max(20, Swift.min(200, intervaloMs))
        let t = Timer(timeInterval: Double(ms) / 1000.0, repeats: true) { [weak self] _ in self?.tickEnlace() }
        t.tolerance = 0.001
        RunLoop.current.add(t, forMode: .default)
        timerTx = t
    }

    // MARK: Conexión MFi (hilo principal)
    @objc private func accesorioConectado(_ n: Notification) {
        agregarLog("NOTIF: iOS ha conectado un accesorio.")
        if !conectado && reconexionBloqueadaHasta == nil { buscarYConectarAuto() }
    }

    @objc private func accesorioDesconectado(_ n: Notification) {
        if let acc = n.userInfo?[EAAccessoryKey] as? EAAccessory, accesorioActualID != -1, acc.connectionID != accesorioActualID {
            agregarLog("NOTIF: se desconectó otro accesorio (\(acc.name)), ignorado."); return
        }
        agregarLog("NOTIF: Helicóptero desconectado. Gas a 0.")
        cerrarSesion()
    }

    func abrirSelectorBluetoothMFi() {
        agregarLog("Abriendo selector Bluetooth MFi de Apple...")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil, completion: { [weak self] error in
            if let err = error { self?.agregarLog("Selector MFi: \(err.localizedDescription)") }
            else { self?.agregarLog("Accesorio seleccionado."); self?.buscarYConectarAuto() }
        })
    }

    func buscarYConectarAuto() {
        if let hasta = reconexionBloqueadaHasta, Date() < hasta { return }
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty { return }
        let preferidos = ["com.silverlit.datapath", "com.issc.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
        for acc in accesorios {
            for proto in preferidos where acc.protocolStrings.contains(proto) {
                if conectar(acc: acc, proto: proto) { return }
            }
            if let primero = acc.protocolStrings.first, conectar(acc: acc, proto: primero) { return }
        }
    }

    func conectar(acc: EAAccessory, proto: String) -> Bool {
        cerrarSesion()
        agregarLog("Conectando con \(acc.name) [\(proto)]...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error: no se pudo abrir EASession con '\(proto)'."); return false
        }
        session = ses
        nombreDispositivo = acc.name
        protoActivo = proto
        accesorioActualID = acc.connectionID
        gasObjetivo = 0
        perform(#selector(abrirStreamsEnHilo(_:)), on: hilo, with: ses, waitUntilDone: true)
        framesEnviados = 0; framesDescartados = 0; gasEnviado = 0; armado = false
        historialBateria = []; bateriaReposo = nil; minutosRestantes = nil
        conectado = true
        agregarLog(">>> CONECTADO a \(acc.name). Enviando \(perfilEnUso.nombre) a \(1000 / Swift.max(1, intervaloMs)) Hz con gas 0. <<<")
        return true
    }

    func cerrarSesion() {
        perform(#selector(cerrarStreamsEnHilo), on: hilo, with: nil, waitUntilDone: true)
        session = nil; accesorioActualID = -1
        conectado = false; nombreDispositivo = ""; protoActivo = ""
        timerManiobra?.invalidate(); maniobraActiva = false
        if reproduciendo != nil { reproduccionDetener(motivo: "cortada por desconexión") }
        if grabando { grabacionDetener() }
        if case .probando = asistente { asistente = .inactivo; perfilEnPrueba = nil }
        gasObjetivo = 0; gasEnviado = 0; armado = false; hzReal = 0
    }

    /// Cierra la sesión MFi y bloquea la reconexión automática 6 s. iOS mantiene el Bluetooth
    /// emparejado, así que el heli deja de recibir tramas durante esos 6 s.
    func paradaDura() {
        if let hasta = reconexionBloqueadaHasta, Date() < hasta {
            agregarLog("Parada dura ya en curso."); return
        }
        agregarLog("⛔ PARADA DURA: sesión MFi cerrada. Sin tramas durante 6 s, luego reconecta.")
        paradaTotalEmergencia(motivo: "parada dura")
        reconexionBloqueadaHasta = Date(timeIntervalSinceNow: 6.0)
        cerrarSesion()
    }

    // MARK: Streams (hilo de enlace)
    @objc private func abrirStreamsEnHilo(_ obj: Any) {
        guard let ses = obj as? EASession else { return }
        let rl = RunLoop.current
        if let inp = ses.inputStream { inp.delegate = self; inp.schedule(in: rl, forMode: .default); inp.open() }
        if let out = ses.outputStream { out.delegate = self; out.schedule(in: rl, forMode: .default); out.open() }
        gasEnv = 0; ticksEnCero = 0; armadoInterno = false
        txTotal = 0; txDescartados = 0; contadorHz = 0; rxBuffer = []
        cerrojo.lock(); sesionHilo = ses; rafagaStop = 0; cerrojo.unlock()
    }

    @objc private func cerrarStreamsEnHilo() {
        cerrojo.lock(); let ses = sesionHilo; sesionHilo = nil; cerrojo.unlock()
        guard let s = ses else { return }
        let rl = RunLoop.current
        s.inputStream?.close(); s.outputStream?.close()
        s.inputStream?.remove(from: rl, forMode: .default); s.outputStream?.remove(from: rl, forMode: .default)
        s.inputStream?.delegate = nil; s.outputStream?.delegate = nil
    }

    // MARK: Bucle de envío (hilo de enlace)
    private func tickEnlace() {
        let ahora = Date()
        let hueco = ahora.timeIntervalSince(tUltimoTick)
        tUltimoTick = ahora

        cerrojo.lock()
        let c = consigna
        let ses = sesionHilo
        let stops = rafagaStop
        rafagaStop = 0
        cerrojo.unlock()
        guard let out = ses?.outputStream else { return }

        if hueco > 0.25 { agregarLog(String(format: "⚠️ Hueco en el hilo de enlace: %.0f ms", hueco * 1000)) }

        // Ráfaga de parada inmediata
        if stops > 0 {
            gasEnv = 0; ticksEnCero = 0; armadoInterno = false
            let stop = Codificador.trama(perfil: c.perfil, rotor: 0, pitch: 127, yaw: 127, trim: c.trim, match: c.match)
            for _ in 0..<stops { _ = escribir(out, stop.bytes) }
        }

        // Máquina de estados del gas
        let objetivo = Swift.min(Swift.max(0.0, c.gasObjetivo), c.tope)
        if objetivo <= 0 {
            gasEnv = 0
            ticksEnCero = Swift.min(ticksEnCero + 1, 100_000)
            armadoInterno = !c.armadoActivo || ticksEnCero >= c.ticksArmado
        } else {
            var subir = true
            if c.armadoActivo && gasEnv <= 0 && ticksEnCero < c.ticksArmado {
                ticksEnCero += 1
                armadoInterno = ticksEnCero >= c.ticksArmado
                if !armadoInterno { subir = false }
                else { agregarLog("✅ Armado (\(c.ticksArmado) tramas a gas 0). Subiendo hacia \(Int(objetivo)) %.") }
            }
            if subir {
                if gasEnv <= 0 { agregarLog("▶️ Rotor: rampa hacia \(Int(objetivo)) % (rotor \(rotor(objetivo, c.perfil))/\(c.perfil.rotorMax)).") }
                if objetivo > gasEnv { gasEnv = Swift.min(objetivo, gasEnv + c.rampa) } else { gasEnv = objetivo }
                ticksEnCero = 0
                armadoInterno = true
            }
        }

        let t = Codificador.trama(perfil: c.perfil, rotor: rotor(gasEnv, c.perfil), pitch: Int(c.pitch), yaw: Int(c.yaw), trim: c.trim, match: c.match)
        if escribir(out, t.bytes) { txTotal += 1 } else { txDescartados += 1 }

        contadorHz += 1
        var hz: Int? = nil
        if ahora.timeIntervalSince(tUltimoHz) >= 1.0 { hz = contadorHz; contadorHz = 0; tUltimoHz = ahora }

        // Publicar a la interfaz a 10 Hz (no a 20) para no saturar el redibujado
        ticksDesdePublicacion += 1
        if ticksDesdePublicacion >= 2 || hz != nil {
            ticksDesdePublicacion = 0
            let ge = gasEnv, tv = t.visible, tx = txTotal, td = txDescartados, arm = armadoInterno
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.gasEnviado = ge; self.tramaVisible = tv
                self.framesEnviados = tx; self.framesDescartados = td; self.armado = arm
                if let h = hz { self.hzReal = h }
            }
        }
    }

    private func rotor(_ porcentaje: Double, _ p: Perfil) -> Int {
        Int(((Swift.max(0.0, Swift.min(100.0, porcentaje)) / 100.0) * Double(p.rotorMax)).rounded())
    }

    private func escribir(_ out: OutputStream, _ bytes: [UInt8]) -> Bool {
        guard out.hasSpaceAvailable else { return false }
        return out.write(bytes, maxLength: bytes.count) == bytes.count
    }

    // Helpers para la interfaz (hilo principal)
    func rotorDe(_ porcentaje: Double) -> Int { rotor(porcentaje, perfilEnUso) }
    func tramaActual() -> (bytes: [UInt8], visible: String) {
        Codificador.trama(perfil: perfilEnUso, rotor: rotorDe(gasEnviado), pitch: Int(pitch), yaw: Int(yaw), trim: trim, match: match)
    }

    // MARK: Acciones (hilo principal)
    func aplicarJoystick(dx: Double, dy: Double) {
        let s = Swift.max(0.1, Swift.min(1.0, sensibilidad))
        let e = modoFacil ? 0.5 : 0.0
        func expo(_ v: Double) -> Double { v * (1.0 - e) + v * v * v * e }
        var y = 127.0 + expo(dx) * 127.0 * s
        var p = 127.0 - expo(dy) * 127.0 * s
        if invertirYaw { y = 254.0 - y }
        if invertirPitch { p = 254.0 - p }
        yaw = Swift.max(0.0, Swift.min(255.0, y))
        pitch = Swift.max(0.0, Swift.min(255.0, p))
    }
    func centrarJoystick() { yaw = 127; pitch = 127 }
    func fijarGas(_ v: Double) { guard !maniobraActiva else { return }; gasObjetivo = Swift.max(0.0, Swift.min(100.0, v)) }
    func ajustarTrim(_ d: Int) { trim = Swift.max(0, Swift.min(perfilEnUso.trimMax, trim + d)) }
    func ciclarLuz() { perfilActivo.luz = (perfilActivo.luz + 1) % 8; agregarLog("Luz = \(perfilActivo.luz).") }

    /// Botones de dirección del modo fácil: deflexión limitada al 55 % del recorrido.
    func empujar(dx: Double, dy: Double) { aplicarJoystick(dx: dx * 0.55, dy: dy * 0.55) }

    func hover() {
        guard conectado, !maniobraActiva else { return }
        gasObjetivo = Swift.min(gasHover, topeActual)
        agregarLog("🪁 HOVER a \(Int(gasObjetivo)) %. Ajusta con − / + hasta que se mantenga a la altura.")
    }

    func ajustarHover(_ d: Double) {
        gasHover = Swift.max(10.0, Swift.min(100.0, gasHover + d))
        if gasObjetivo > 0 && !maniobraActiva { gasObjetivo = Swift.min(gasHover, topeActual) }
    }

    private func registrarBateria() {
        guard let pct = bateriaPorcentaje else { return }
        let ahora = Date()
        historialBateria.append((ahora, pct))
        historialBateria.removeAll { ahora.timeIntervalSince($0.0) > 180 }
        let ult10 = historialBateria.filter { ahora.timeIntervalSince($0.0) <= 10 }.map { $0.1 }
        bateriaReposo = ult10.max()
        let ventana = historialBateria.filter { ahora.timeIntervalSince($0.0) <= 120 }
        guard ventana.count >= 30, let primero = ventana.first, ahora.timeIntervalSince(primero.0) >= 60 else { minutosRestantes = nil; return }
        let xs = ventana.map { $0.0.timeIntervalSince(primero.0) }
        let ys = ventana.map { Double($0.1) }
        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = xs.map { $0 * $0 }.reduce(0, +)
        let sxy = zip(xs, ys).map { $0.0 * $0.1 }.reduce(0, +)
        let den = n * sxx - sx * sx
        guard den != 0 else { minutosRestantes = nil; return }
        let pendiente = (n * sxy - sx * sy) / den   // % por segundo (negativa si se descarga)
        if pendiente < -0.003, let actual = bateriaReposo, actual > 25 {
            minutosRestantes = Int((Double(actual - 25) / -pendiente / 60.0).rounded())
        } else {
            minutosRestantes = nil
        }
    }

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

    func ejecutarPulso(potencia: Double, duracion: Double = 2.0) {
        guard conectado else { agregarLog("No conectado: pulsa Vincular."); return }
        guard !maniobraActiva else { return }
        maniobraActiva = true
        let efectiva = Swift.min(potencia, topeActual)
        let tRampa = (efectiva / Swift.max(0.1, rampaPorTick)) * 0.05
        let total = Double(ticksArmado) * 0.05 + tRampa + duracion
        agregarLog("=== PULSO \(Int(efectiva)) % (rotor \(rotorDe(efectiva))) durante \(String(format: "%.1f", duracion)) s ===")
        gasObjetivo = efectiva
        programarManiobra(intervalo: total, repite: false) { [weak self] _ in
            guard let self = self else { return }
            self.gasObjetivo = 0; self.maniobraActiva = false
            self.agregarLog("Fin de pulso. Gas 0.")
        }
    }

    func despegueSuave() {
        guard conectado, !maniobraActiva else { return }
        let obj = Swift.min(potenciaDespegue, topeActual)
        agregarLog("🛫 Despegue asistido hacia \(Int(obj)) %. El gas queda fijo: Aterrizar o STOP.")
        gasObjetivo = obj
    }

    func aterrizarSuave() {
        guard conectado, !maniobraActiva else { return }
        maniobraActiva = true
        agregarLog("🛬 Aterrizaje: bajando 2 % cada 80 ms...")
        programarManiobra(intervalo: 0.08, repite: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.gasObjetivo = Swift.max(0.0, self.gasObjetivo - 2.0)
            if self.gasObjetivo <= 0 { t.invalidate(); self.maniobraActiva = false; self.agregarLog("Aterrizado. Gas 0.") }
        }
    }

    func paradaTotalEmergencia(motivo: String = "botón STOP") {
        timerManiobra?.invalidate()
        if reproduciendo != nil { reproduccionDetener(motivo: "cortada por \(motivo)") }
        if grabando { grabacionDetener() }
        maniobraActiva = false
        gasObjetivo = 0; pitch = 127; yaw = 127
        cerrojo.lock(); rafagaStop = 10; cerrojo.unlock()
        gasEnviado = 0
        agregarLog("🛑 PARADA TOTAL (\(motivo)): ráfaga de 10 tramas de rotor 0 y gas fijo a 0.")
    }

    private func programarManiobra(intervalo: TimeInterval, repite: Bool, bloque: @escaping (Timer) -> Void) {
        timerManiobra?.invalidate()
        let t = Timer(timeInterval: intervalo, repeats: repite, block: bloque)
        RunLoop.main.add(t, forMode: .common)
        timerManiobra = t
    }

    // MARK: Asistente (hilo principal)
    func asistenteIniciar(desde idx: Int = 0) {
        guard conectado else { agregarLog("Asistente: conecta el heli primero."); return }
        guard idx < Perfil.candidatos.count else { asistente = .fracaso; perfilEnPrueba = nil; return }
        timerManiobra?.invalidate()
        let p = Perfil.candidatos[idx]
        perfilEnPrueba = p
        trim = p.trimNeutro
        gasObjetivo = 0
        maniobraActiva = true
        asistente = .probando(idx)
        let ejemplo = Codificador.trama(perfil: p, rotor: 0, pitch: 127, yaw: 127, trim: p.trimNeutro, match: match).visible
        agregarLog("🧪 ASISTENTE \(idx + 1)/\(Perfil.candidatos.count): \(p.nombre) · neutro = \(ejemplo)")
        var fase = 0
        programarManiobra(intervalo: 0.1, repite: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            fase += 1
            if fase == 15 {
                self.gasObjetivo = Swift.min(self.potenciaAsistente, self.topeActual)
                self.agregarLog("🧪 Rotor a \(Int(self.gasObjetivo)) % (\(self.rotorDe(self.gasObjetivo))/\(p.rotorMax)) durante 2,5 s...")
            } else if fase >= 40 {
                t.invalidate()
                self.gasObjetivo = 0
                self.maniobraActiva = false
                self.asistente = .pregunta(idx)
                self.agregarLog("🧪 Fin de prueba \(idx + 1). ¿Han girado las palas?")
            }
        }
    }

    func asistenteRespuesta(giro: Bool) {
        guard case .pregunta(let idx) = asistente else { return }
        if giro {
            let p = Perfil.candidatos[idx]
            perfilActivo = p
            perfilEnPrueba = nil
            trim = p.trimNeutro
            asistente = .exito(idx)
            agregarLog("🏆 PATRÓN RECONOCIDO: \(p.nombre). Guardado como perfil activo.")
        } else {
            agregarLog("Asistente: descartado \(Perfil.candidatos[idx].nombre).")
            asistenteIniciar(desde: idx + 1)
        }
    }

    func asistenteRepetir() {
        guard case .pregunta(let idx) = asistente else { return }
        asistenteIniciar(desde: idx)
    }

    func asistenteCancelar() {
        timerManiobra?.invalidate()
        maniobraActiva = false
        gasObjetivo = 0
        perfilEnPrueba = nil
        trim = perfilActivo.trimNeutro
        asistente = .inactivo
        agregarLog("Asistente cancelado. Perfil activo: \(perfilActivo.nombre).")
    }

    // MARK: Grabar y reproducir vuelos (hilo principal, bucle abierto)
    struct Muestra: Codable, Equatable { var t: Double; var gas: Double; var pitch: Double; var yaw: Double }
    struct Grabacion: Codable, Identifiable, Equatable {
        var id: UUID
        var nombre: String
        var muestras: [Muestra]
        var duracion: Double { muestras.last?.t ?? 0 }
    }
    @Published var grabaciones: [Grabacion] = [] { didSet { guardarGrabaciones() } }
    @Published var grabando = false
    @Published var reproduciendo: Grabacion? = nil
    @Published var progresoReproduccion: Double = 0
    @Published var repetirEnBucle = false
    private var timerGrabacion: Timer?
    private var timerReproduccion: Timer?
    private var muestrasActuales: [Muestra] = []
    private var tInicioGrabacion = Date()

    func cargarGrabaciones() {
        if let d = UserDefaults.standard.data(forKey: "grabaciones"), let g = try? JSONDecoder().decode([Grabacion].self, from: d) {
            grabaciones = g
        }
    }
    private func guardarGrabaciones() {
        if let d = try? JSONEncoder().encode(grabaciones) { UserDefaults.standard.set(d, forKey: "grabaciones") }
    }

    func grabacionIniciar() {
        guard conectado, !grabando, reproduciendo == nil else { return }
        muestrasActuales = []
        tInicioGrabacion = Date()
        grabando = true
        agregarLog("⏺ Grabando vuelo: mueve los mandos con normalidad. Pulsa Detener al terminar (con el heli posado).")
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.grabando else { return }
            let el = Date().timeIntervalSince(self.tInicioGrabacion)
            self.muestrasActuales.append(Muestra(t: el, gas: self.gasObjetivo, pitch: self.pitch, yaw: self.yaw))
            if el > 180 { self.grabacionDetener() }
        }
        RunLoop.main.add(t, forMode: .common)
        timerGrabacion = t
    }

    func grabacionDetener() {
        guard grabando else { return }
        timerGrabacion?.invalidate(); timerGrabacion = nil
        grabando = false
        var m = muestrasActuales
        let fin = (m.last?.t ?? 0)
        m.append(Muestra(t: fin + 0.05, gas: 0, pitch: 127, yaw: 127))
        m.append(Muestra(t: fin + 2.0, gas: 0, pitch: 127, yaw: 127))
        let g = Grabacion(id: UUID(), nombre: "Vuelo \(grabaciones.count + 1)", muestras: m)
        grabaciones.append(g)
        agregarLog("⏹ Grabación guardada: \(g.nombre), \(String(format: "%.1f", g.duracion)) s, \(m.count) muestras.")
    }

    func reproducir(_ g: Grabacion) {
        guard conectado, !maniobraActiva, !grabando, reproduciendo == nil else { agregarLog("No se puede reproducir ahora."); return }
        reproduciendo = g
        maniobraActiva = true
        progresoReproduccion = 0
        agregarLog("▶️ Reproduciendo \(g.nombre) (\(String(format: "%.1f", g.duracion)) s)\(repetirEnBucle ? " en bucle" : ""). STOP corta en cualquier momento.")
        var inicio = Date()
        var idx = 0
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self = self, let g = self.reproduciendo else { t.invalidate(); return }
            let el = Date().timeIntervalSince(inicio)
            while idx + 1 < g.muestras.count && g.muestras[idx + 1].t <= el { idx += 1 }
            if idx < g.muestras.count {
                let m = g.muestras[idx]
                self.gasObjetivo = m.gas; self.pitch = m.pitch; self.yaw = m.yaw
            }
            self.progresoReproduccion = g.duracion > 0 ? Swift.min(1.0, el / g.duracion) : 1
            if el >= g.duracion {
                if self.repetirEnBucle {
                    inicio = Date(); idx = 0
                    self.agregarLog("🔁 Repitiendo \(g.nombre).")
                } else {
                    self.reproduccionDetener(motivo: "terminada")
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timerReproduccion = t
    }

    func reproduccionDetener(motivo: String = "detenida") {
        timerReproduccion?.invalidate(); timerReproduccion = nil
        guard let g = reproduciendo else { return }
        reproduciendo = nil
        maniobraActiva = false
        gasObjetivo = 0; pitch = 127; yaw = 127
        progresoReproduccion = 0
        agregarLog("⏹ Reproducción de \(g.nombre) \(motivo). Gas 0.")
    }

    func borrarGrabacion(_ g: Grabacion) { grabaciones.removeAll { $0.id == g.id } }

    func renombrarGrabacion(_ g: Grabacion, _ nombre: String) {
        if let i = grabaciones.firstIndex(where: { $0.id == g.id }) { grabaciones[i].nombre = nombre }
    }

    // MARK: Stream delegate (hilo de enlace)
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable: leerEntrada(aStream as? InputStream)
        case .errorOccurred: agregarLog("STREAM: error de enlace (\(aStream.streamError?.localizedDescription ?? "desconocido")).")
        case .endEncountered:
            agregarLog("STREAM: conexión cerrada por el accesorio.")
            DispatchQueue.main.async { [weak self] in self?.cerrarSesion() }
        default: break
        }
    }

    private func leerEntrada(_ inp: InputStream?) {
        guard let inp = inp else { return }
        var buf = [UInt8](repeating: 0, count: 128)
        var leidos: [UInt8] = []
        while inp.hasBytesAvailable {
            let n = inp.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            leidos.append(contentsOf: buf[0..<n])
        }
        guard !leidos.isEmpty else { return }
        rxBuffer.append(contentsOf: leidos)
        if rxBuffer.count > 64 { rxBuffer.removeFirst(rxBuffer.count - 64) }
        let hex = leidos.map { String(format: "%02X", $0) }.joined(separator: " ")
        let texto = String(rxBuffer.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "·" })

        // Respuesta observada: 'x' (0x78), nivel de batería (múltiplo de 7, 168 = lleno), flag, 0.
        var nivel: Int? = nil
        var flag: Int? = nil
        if let idx = rxBuffer.lastIndex(of: 0x78), idx + 2 < rxBuffer.count {
            nivel = Int(rxBuffer[idx + 1])
            flag = Int(rxBuffer[idx + 2])
        }
        let logAhora = Date().timeIntervalSince(tUltimoLogRx) > 2.0
        if logAhora { tUltimoLogRx = Date() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rxHex = hex; self.rxTexto = texto
            if let n = nivel { self.rxNivel = n; self.registrarBateria() }
            if let f = flag { self.rxFlag = f }
            if logAhora {
                let pct = self.bateriaPorcentaje.map { "\($0) %" } ?? "?"
                self.agregarLog("RX heli: \(hex) → batería \(pct)\(self.rxFlag != 0 ? " · flag \(self.rxFlag)" : "")")
            }
        }
    }

    func agregarLog(_ s: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.agregarLog(s) }
            return
        }
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        log = "[\(df.string(from: Date()))] \(s)\n" + log
        if log.count > 20000 { log = String(log.prefix(20000)) }
    }
}

func nombreCanal(_ m: Int) -> String {
    switch m { case 0: return "A"; case 1: return "B"; case 2: return "C"; default: return "D" }
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
            RutasView(pilot: pilot).tabItem { Label("Rutas", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
            CabinaView(pilot: pilot).tabItem { Label("Cabina", systemImage: "slider.horizontal.3") }
            AsistenteView(pilot: pilot).tabItem { Label("Diagnóstico", systemImage: "wand.and.stars") }
            AjustesView(pilot: pilot).tabItem { Label("Protocolo", systemImage: "waveform.path.ecg") }
        }
        .onChange(of: scenePhase) { fase in
            if fase != .active && (pilot.gasObjetivo > 0 || pilot.gasEnviado > 0) {
                pilot.paradaTotalEmergencia(motivo: "app en segundo plano")
            }
        }
    }
}

// =====================================================================
// MARK: - Componentes comunes
// =====================================================================
struct BannerConexion: View {
    @ObservedObject var pilot: HeliPilot
    var body: some View {
        Section {
            HStack {
                Circle().fill(pilot.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pilot.conectado ? "CONECTADO: \(pilot.nombreDispositivo)" : "🔴 HELICÓPTERO DESCONECTADO").bold()
                    if pilot.conectado {
                        Text(verbatim: "\(pilot.hzReal) Hz · \(pilot.framesEnviados) tx · \(pilot.framesDescartados) desc · canal \(nombreCanal(pilot.match))")
                            .font(.caption2).foregroundColor(.secondary)
                        Text(verbatim: "Perfil: \(pilot.perfilEnUso.nombre)" + (pilot.bateriaPorcentaje.map { " · 🔋 \($0) %" } ?? "")).font(.caption2).foregroundColor(.blue)
                    } else if let hasta = pilot.reconexionBloqueadaHasta, hasta > Date() {
                        Text(verbatim: "⛔ Parada dura: reconexión pausada unos segundos.").font(.caption2).foregroundColor(.red)
                    } else {
                        Text(verbatim: "Enciende el heli. Si no conecta solo: Ajustes → Bluetooth → Chatboard, o pulsa Vincular.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if pilot.conectado {
                    Text(verbatim: pilot.armado ? "ESC listo" : "armando…").font(.caption2).bold()
                        .foregroundColor(pilot.armado ? .green : .orange)
                }
            }
            if !pilot.conectado {
                Button(action: { pilot.abrirSelectorBluetoothMFi() }) {
                    HStack { Spacer(); Image(systemName: "antenna.radiowaves.left.and.right"); Text(verbatim: "📲 VINCULAR / RECONECTAR").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent).tint(.blue)
            }
        }
    }
}

struct BotonesStop: View {
    @ObservedObject var pilot: HeliPilot
    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button(action: { pilot.paradaTotalEmergencia() }) {
                    HStack { Spacer(); Image(systemName: "stop.circle.fill"); Text(verbatim: "STOP").bold(); Spacer() }.padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                Button(action: { pilot.paradaDura() }) {
                    HStack { Spacer(); Image(systemName: "bolt.slash.fill"); Text(verbatim: "PARADA DURA").bold(); Spacer() }.padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(.red)
            }
            Text(verbatim: "STOP manda rotor 0 sin parar (es el corte normal). PARADA DURA cierra la sesión y deja al heli 6 s sin tramas antes de reconectar.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}

// =====================================================================
// MARK: - TAB VUELO
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
                        PalancaGas(pilot: pilot).frame(width: horizontal ? 110 : 90)
                        VStack(spacing: 10) {
                            panelCentral
                            Spacer(minLength: 0)
                            botonesTrim
                        }
                        .frame(maxWidth: .infinity)
                        if pilot.modoFacil {
                            BotonesDireccion(pilot: pilot).frame(width: ladoJoystick(geo), height: ladoJoystick(geo))
                        } else {
                            JoystickPad(pilot: pilot).frame(width: ladoJoystick(geo), height: ladoJoystick(geo))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    barraInferior
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                if !pilot.conectado { overlayDesconectado }
            }
        }
    }

    private func ladoJoystick(_ geo: GeometryProxy) -> CGFloat {
        let alto = geo.size.height - 150
        let ancho = geo.size.width - 90 - 12 - 12 - 24 - 110
        return Swift.max(160, Swift.min(320, Swift.min(alto, ancho)))
    }

    var barraSuperior: some View {
        HStack(spacing: 10) {
            Circle().fill(pilot.conectado ? Color.green : Color.red).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: pilot.conectado ? pilot.nombreDispositivo : "Desconectado").font(.caption).bold()
                Text(verbatim: pilot.conectado ? "\(pilot.hzReal) Hz · canal \(nombreCanal(pilot.match)) · \(pilot.armado ? "listo" : "armando…")" : "Ajustes → Bluetooth → Chatboard")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { pilot.modoFacil.toggle() }) {
                Text(verbatim: pilot.modoFacil ? "FÁCIL" : "PRO").font(.caption2).bold().padding(6)
            }
            .buttonStyle(.bordered).tint(pilot.modoFacil ? .green : .blue)
            Button(action: { pilot.ciclarLuz() }) {
                HStack(spacing: 2) { Image(systemName: "lightbulb.fill"); Text(verbatim: "\(pilot.perfilActivo.luz)").font(.caption2) }.padding(6)
            }
            .buttonStyle(.bordered).tint(.yellow)
            Button(action: { pilot.paradaDura() }) {
                Image(systemName: "bolt.slash.fill").padding(6)
            }
            .buttonStyle(.bordered).tint(.red)
            Button(action: { pilot.paradaTotalEmergencia() }) {
                HStack(spacing: 6) { Image(systemName: "stop.circle.fill"); Text(verbatim: "STOP").bold() }
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(.top, 4)
    }

    var panelCentral: some View {
        VStack(spacing: 6) {
            Text(verbatim: "GAS").font(.caption2).foregroundColor(.secondary)
            Text(verbatim: "\(Int(pilot.gasEnviado)) %")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundColor(pilot.gasEnviado > 0 ? (pilot.gasEnviado > 60 ? .red : .green) : .secondary)
            Text(verbatim: "obj \(Int(pilot.gasObjetivo)) % · rotor \(pilot.rotorDe(pilot.gasEnviado))/\(pilot.perfilEnUso.rotorMax)")
                .font(.caption2).foregroundColor(.secondary)
            Text(verbatim: pilot.modoSalon ? "SALÓN · tope \(Int(pilot.topeSalon)) %" : "LIBRE · sin tope")
                .font(.caption2).bold().foregroundColor(pilot.modoSalon ? .green : .red)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((pilot.modoSalon ? Color.green : Color.red).opacity(0.15)).cornerRadius(6)
            Divider()
            HStack {
                VStack { Text(verbatim: "PITCH").font(.caption2).foregroundColor(.secondary); Text(verbatim: "\(Int(pilot.pitch))").font(.footnote).bold().monospacedDigit() }
                Spacer()
                VStack { Text(verbatim: "YAW").font(.caption2).foregroundColor(.secondary); Text(verbatim: "\(Int(pilot.yaw))").font(.footnote).bold().monospacedDigit() }
            }
            .padding(.horizontal, 4)
            if let b = pilot.bateriaReposo ?? pilot.bateriaPorcentaje {
                Text(verbatim: "🔋 \(b) %" + (pilot.minutosRestantes.map { " · ≈ \($0) min" } ?? "") + (pilot.rxFlag != 0 ? " · flag \(pilot.rxFlag)" : ""))
                    .font(.caption).bold().foregroundColor(b < 30 ? .red : (b < 60 ? .orange : .green))
            }
            if pilot.modoFacil {
                HStack(spacing: 6) {
                    Button(action: { pilot.ajustarHover(-2) }) { Image(systemName: "minus").frame(width: 26, height: 26) }.buttonStyle(.bordered)
                    Button(action: { pilot.hover() }) {
                        VStack(spacing: 0) { Text(verbatim: "HOVER").bold(); Text(verbatim: "\(Int(pilot.gasHover)) %").font(.caption2) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(!pilot.conectado || pilot.maniobraActiva)
                    Button(action: { pilot.ajustarHover(2) }) { Image(systemName: "plus").frame(width: 26, height: 26) }.buttonStyle(.bordered)
                }
                Button(action: { pilot.aterrizarSuave() }) { Text(verbatim: "🛬 ATERRIZAR").bold().frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.blue).disabled(pilot.gasObjetivo <= 0 || pilot.maniobraActiva)
            }
            if let hasta = pilot.reconexionBloqueadaHasta, hasta > Date() {
                Text(verbatim: "⛔ parada dura: sin tramas, reconecta en unos segundos").font(.caption2).foregroundColor(.red)
            }
        }
    }

    var botonesTrim: some View {
        VStack(spacing: 4) {
            Text(verbatim: "TRIM \(pilot.trim) / \(pilot.perfilEnUso.trimMax)").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button(action: { pilot.ajustarTrim(-1) }) { Image(systemName: "arrow.turn.up.left").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.bordered)
                Button(action: { pilot.trim = pilot.perfilEnUso.trimNeutro }) { Text(verbatim: "\(pilot.perfilEnUso.trimNeutro)").font(.caption).frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.bordered)
                Button(action: { pilot.ajustarTrim(1) }) { Image(systemName: "arrow.turn.up.right").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.bordered)
            }
        }
    }

    var barraInferior: some View {
        HStack {
            Text(verbatim: "TX \(pilot.tramaVisible.isEmpty ? "--" : pilot.tramaVisible)")
                .font(.system(.caption2, design: .monospaced)).foregroundColor(.blue).lineLimit(1)
            Spacer()
            Text(verbatim: "RX \(pilot.rxTexto.isEmpty ? "--" : String(pilot.rxTexto.suffix(12)))")
                .font(.system(.caption2, design: .monospaced)).foregroundColor(.purple).lineLimit(1)
        }
    }

    var overlayDesconectado: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 44))
            Text(verbatim: "Helicóptero desconectado").font(.title3).bold()
            Text(verbatim: "Enciende el heli. Si iOS no lo reconecta solo: Ajustes → Bluetooth → Chatboard, o pulsa Vincular. Los mandos se activan al conectar.")
                .font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
            Button(action: { pilot.abrirSelectorBluetoothMFi() }) { Text(verbatim: "📲 VINCULAR / RECONECTAR").bold().padding(.horizontal, 8) }
                .buttonStyle(.borderedProminent).tint(.blue)
        }
        .padding(24).background(Color(UIColor.secondarySystemBackground).opacity(0.97)).cornerRadius(18).padding(30)
    }
}

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
                RoundedRectangle(cornerRadius: 18).fill(Color(UIColor.secondarySystemBackground))
                if tope < 100 {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.red.opacity(0.14)).frame(height: h * CGFloat(1.0 - tope / 100.0))
                        Spacer(minLength: 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                RoundedRectangle(cornerRadius: 18).fill(Color.green.opacity(0.35))
                    .frame(height: Swift.max(0, h * CGFloat(pilot.gasEnviado / 100.0)))
                VStack {
                    ForEach([100, 75, 50, 25], id: \.self) { m in
                        Text(verbatim: "\(m)").font(.system(size: 9)).foregroundColor(.secondary); Spacer()
                    }
                    Text(verbatim: "0").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
                Capsule().fill(pilot.maniobraActiva ? Color.gray : Color.orange)
                    .frame(width: w - 10, height: alturaKnob)
                    .overlay(Text(verbatim: "\(Int(pilot.gasObjetivo))").font(.caption).bold().foregroundColor(.white))
                    .offset(y: -recorrido * CGFloat(pilot.gasObjetivo / 100.0))
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
                Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2).frame(width: r * 2, height: r * 2)
                Path { p in
                    p.move(to: CGPoint(x: lado / 2, y: lado / 2 - r)); p.addLine(to: CGPoint(x: lado / 2, y: lado / 2 + r))
                    p.move(to: CGPoint(x: lado / 2 - r, y: lado / 2)); p.addLine(to: CGPoint(x: lado / 2 + r, y: lado / 2))
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                VStack { Text(verbatim: "▲ adelante").font(.system(size: 9)).foregroundColor(.secondary); Spacer(); Text(verbatim: "▼ atrás").font(.system(size: 9)).foregroundColor(.secondary) }.padding(6)
                HStack { Text(verbatim: "◀ izq").font(.system(size: 9)).foregroundColor(.secondary); Spacer(); Text(verbatim: "der ▶").font(.system(size: 9)).foregroundColor(.secondary) }.padding(6)
                Circle().fill(activo ? Color.blue : (pilot.conectado ? Color.blue.opacity(0.75) : Color.gray))
                    .frame(width: radioKnob * 2, height: radioKnob * 2).shadow(radius: activo ? 6 : 2).offset(pos)
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
                        pos = CGSize(width: dx, height: dy); activo = true
                        pilot.aplicarJoystick(dx: Double(dx / r), dy: Double(dy / r))
                    }
                    .onEnded { _ in pos = .zero; activo = false; pilot.centrarJoystick() }
            )
        }
    }
}

// Botones de dirección del modo fácil: mantener pulsado mueve, soltar centra.
struct BotonesDireccion: View {
    @ObservedObject var pilot: HeliPilot
    var body: some View {
        GeometryReader { g in
            let lado = Swift.min(g.size.width, g.size.height)
            let b = Swift.max(40, lado / 3 - 6)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: b, height: b)
                    BotonEmpuje(pilot: pilot, icono: "arrow.up", texto: "adelante", dx: 0, dy: -1, lado: b)
                    Color.clear.frame(width: b, height: b)
                }
                HStack(spacing: 6) {
                    BotonEmpuje(pilot: pilot, icono: "arrow.counterclockwise", texto: "girar izq", dx: -1, dy: 0, lado: b)
                    ZStack {
                        Circle().fill(Color(UIColor.secondarySystemBackground))
                        VStack(spacing: 2) {
                            Text(verbatim: "P \(Int(pilot.pitch))").font(.caption2).monospacedDigit()
                            Text(verbatim: "Y \(Int(pilot.yaw))").font(.caption2).monospacedDigit()
                        }.foregroundColor(.secondary)
                    }.frame(width: b, height: b)
                    BotonEmpuje(pilot: pilot, icono: "arrow.clockwise", texto: "girar der", dx: 1, dy: 0, lado: b)
                }
                HStack(spacing: 6) {
                    Color.clear.frame(width: b, height: b)
                    BotonEmpuje(pilot: pilot, icono: "arrow.down", texto: "atrás", dx: 0, dy: 1, lado: b)
                    Color.clear.frame(width: b, height: b)
                }
            }
            .frame(width: lado, height: lado)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

struct BotonEmpuje: View {
    @ObservedObject var pilot: HeliPilot
    let icono: String
    let texto: String
    let dx: Double
    let dy: Double
    let lado: CGFloat
    @State private var pulsado = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(pulsado ? Color.blue : Color.blue.opacity(pilot.conectado ? 0.22 : 0.08))
            VStack(spacing: 2) {
                Image(systemName: icono).font(.title2)
                Text(verbatim: texto).font(.caption2)
            }
            .foregroundColor(pulsado ? .white : .primary)
        }
        .frame(width: lado, height: lado)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 80, pressing: { p in
            guard pilot.conectado else { return }
            pulsado = p
            if p { pilot.empujar(dx: dx, dy: dy) } else { pilot.centrarJoystick() }
        }, perform: {})
        .onDisappear { if pulsado { pulsado = false; pilot.centrarJoystick() } }
    }
}

// =====================================================================
// MARK: - TAB RUTAS (grabar y repetir vuelos)
// =====================================================================
struct RutasView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                BannerConexion(pilot: pilot)
                BotonesStop(pilot: pilot)

                Section(header: Text(verbatim: "GRABAR UN VUELO"),
                        footer: Text(verbatim: "Graba lo que haces con los mandos (gas, pitch, yaw) 20 veces por segundo. Vuela desde Vuelo o Cabina mientras graba; al detener, la ruta termina siempre con 2 s de gas 0. Máximo 3 minutos.")) {
                    if pilot.grabando {
                        HStack {
                            Circle().fill(Color.red).frame(width: 12, height: 12)
                            Text(verbatim: "Grabando… vuela con normalidad").bold()
                            Spacer()
                            Button(action: { pilot.grabacionDetener() }) { Text(verbatim: "⏹ Detener y guardar").bold() }
                                .buttonStyle(.borderedProminent).tint(.red)
                        }
                    } else {
                        Button(action: { pilot.grabacionIniciar() }) {
                            HStack { Spacer(); Image(systemName: "record.circle"); Text(verbatim: "⏺ EMPEZAR A GRABAR").bold(); Spacer() }
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!pilot.conectado || pilot.reproduciendo != nil || pilot.maniobraActiva)
                    }
                }

                Section(header: Text(verbatim: "RUTAS GUARDADAS"),
                        footer: Text(verbatim: "La reproducción repite los mismos mandos con los mismos tiempos. El heli no tiene sensores de posición, así que el recorrido será parecido, no idéntico: la batería, el aire y el suelo cambian el resultado. Empieza siempre desde el mismo punto, con el heli posado y sin obstáculos cerca. STOP corta en cualquier momento.")) {
                    if pilot.grabaciones.isEmpty {
                        Text(verbatim: "Todavía no hay rutas. Graba la primera arriba.").foregroundColor(.secondary)
                    }
                    ForEach(pilot.grabaciones) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Nombre", text: Binding(get: { g.nombre }, set: { pilot.renombrarGrabacion(g, $0) })).font(.headline)
                                Spacer()
                                Text(verbatim: String(format: "%.1f s · %d muestras", g.duracion, g.muestras.count)).font(.caption).foregroundColor(.secondary)
                            }
                            if pilot.reproduciendo?.id == g.id {
                                ProgressView(value: pilot.progresoReproduccion)
                                Button(action: { pilot.reproduccionDetener() }) {
                                    HStack { Spacer(); Text(verbatim: "⏹ DETENER REPRODUCCIÓN").bold(); Spacer() }
                                }
                                .buttonStyle(.borderedProminent).tint(.red)
                            } else {
                                HStack(spacing: 10) {
                                    Button(action: { pilot.reproducir(g) }) {
                                        HStack { Spacer(); Image(systemName: "play.fill"); Text(verbatim: "REPRODUCIR").bold(); Spacer() }
                                    }
                                    .buttonStyle(.borderedProminent).tint(.green)
                                    .disabled(!pilot.conectado || pilot.reproduciendo != nil || pilot.grabando || pilot.maniobraActiva)
                                    Button(action: { pilot.borrarGrabacion(g) }) { Image(systemName: "trash") }
                                        .buttonStyle(.bordered).tint(.red)
                                        .disabled(pilot.reproduciendo != nil)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Toggle(isOn: $pilot.repetirEnBucle) {
                        VStack(alignment: .leading) {
                            Text(verbatim: "Repetir en bucle").bold()
                            Text(verbatim: "Encadena la ruta una y otra vez hasta que pulses Detener o STOP.").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text(verbatim: "¿Y VUELO AUTÓNOMO DE VERDAD?")) {
                    Text(verbatim: "El heli solo nos envía el nivel de batería: no sabe dónde está. Para que vaya a un sitio y vuelva de forma exacta hace falta que alguien lo vea. La forma correcta es usar la cámara del iPhone como torre de control: el móvil fijo en un trípode mirando la habitación, siguiendo el heli por su color o sus luces, y la app corrigiendo gas, pitch y yaw varias veces por segundo para llevarlo al punto que le marques en pantalla. Eso ya no es repetir mandos: es control en bucle cerrado, y es el siguiente paso de esta app.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Rutas")
        }
    }
}

// =====================================================================
// MARK: - TAB ASISTENTE
// =====================================================================
struct AsistenteView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                BannerConexion(pilot: pilot)
                BotonesStop(pilot: pilot)

                Section(header: Text(verbatim: "¿PARA QUÉ SIRVE ESTO?")) {
                    Text(verbatim: "El asistente ya reconoció el protocolo real del heli (Silverlit oficial, texto hex) y está guardado. No necesitas volver a ejecutarlo salvo que un día deje de responder.")
                        .font(.caption)
                    Text(verbatim: "El canal A/B/C/D no es un modo: es el identificador para volar varios helis en la misma habitación sin que se mezclen. Con un solo heli, cualquiera funciona igual. Déjalo en B.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section(header: Text(verbatim: "RECONOCER EL PATRÓN DEL HELI (solo si hace falta)"),
                        footer: Text(verbatim: "Prueba cada formato de trama con el rotor a la potencia indicada durante 2,5 s (sujeta el heli). Cuando las palas giren, pulsa SÍ y ese perfil queda guardado para la pestaña Vuelo. El primero de la lista es el protocolo real extraído de la app oficial.")) {
                    HStack {
                        Text(verbatim: "Potencia de prueba").bold()
                        Slider(value: $pilot.potenciaAsistente, in: 15...60, step: 1)
                        Text(verbatim: "\(Int(pilot.potenciaAsistente)) %").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Picker(selection: $pilot.match) {
                        Text(verbatim: "A").tag(0); Text(verbatim: "B").tag(1); Text(verbatim: "C").tag(2); Text(verbatim: "D").tag(3)
                    } label: { Text(verbatim: "Canal (btMatch)") }
                    .pickerStyle(.segmented)

                    switch pilot.asistente {
                    case .inactivo, .fracaso, .exito:
                        Button(action: { pilot.asistenteIniciar() }) {
                            HStack { Spacer(); Image(systemName: "wand.and.stars"); Text(verbatim: "▶️ EMPEZAR RECONOCIMIENTO").bold(); Spacer() }
                        }
                        .buttonStyle(.borderedProminent).tint(.green).disabled(!pilot.conectado || pilot.maniobraActiva)
                        if case .fracaso = pilot.asistente {
                            Text(verbatim: "Ningún perfil movió las palas. Revisa que el heli esté cargado y conectado (20 Hz en el banner) y prueba otro canal o más potencia.")
                                .font(.caption).foregroundColor(.red)
                        }
                        if case .exito(let i) = pilot.asistente {
                            Text(verbatim: "🏆 Guardado: \(Perfil.candidatos[i].nombre). Ve a Vuelo.").font(.caption).bold().foregroundColor(.green)
                        }
                    case .probando(let i):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "Probando \(i + 1)/\(Perfil.candidatos.count): \(Perfil.candidatos[i].nombre)").bold()
                            Text(verbatim: Perfil.candidatos[i].descripcion).font(.caption).foregroundColor(.secondary)
                            ProgressView()
                            Text(verbatim: "TX: \(pilot.tramaVisible)").font(.system(.caption, design: .monospaced)).foregroundColor(.blue)
                        }
                        Button(action: { pilot.asistenteCancelar() }) { Text(verbatim: "Cancelar").foregroundColor(.red) }
                    case .pregunta(let i):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "¿Han girado las palas con \(Perfil.candidatos[i].nombre)?").bold()
                        }
                        HStack(spacing: 10) {
                            Button(action: { pilot.asistenteRespuesta(giro: true) }) { HStack { Spacer(); Text(verbatim: "✅ SÍ, giraron").bold(); Spacer() } }
                                .buttonStyle(.borderedProminent).tint(.green)
                            Button(action: { pilot.asistenteRespuesta(giro: false) }) { HStack { Spacer(); Text(verbatim: "❌ No").bold(); Spacer() } }
                                .buttonStyle(.borderedProminent).tint(.red)
                        }
                        Button(action: { pilot.asistenteRepetir() }) { Text(verbatim: "🔁 Repetir esta prueba") }
                        Button(action: { pilot.asistenteCancelar() }) { Text(verbatim: "Cancelar").foregroundColor(.red) }
                    }
                }

                Section(header: Text(verbatim: "PERFILES QUE SE PROBARÁN, EN ORDEN")) {
                    ForEach(Array(Perfil.candidatos.enumerated()), id: \.element.id) { idx, p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: "\(idx + 1). \(p.nombre)").bold()
                                if p.id == pilot.perfilActivo.id { Text(verbatim: "ACTIVO").font(.caption2).bold().foregroundColor(.green) }
                            }
                            Text(verbatim: p.descripcion).font(.caption2).foregroundColor(.secondary)
                            Text(verbatim: "neutro: " + Codificador.trama(perfil: p, rotor: 0, pitch: 127, yaw: 127, trim: p.trimNeutro, match: pilot.match).visible)
                                .font(.system(.caption2, design: .monospaced)).foregroundColor(.blue)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !pilot.maniobraActiva else { return }
                            pilot.perfilActivo = p; pilot.trim = p.trimNeutro
                            pilot.agregarLog("Perfil activo cambiado a mano: \(p.nombre).")
                        }
                    }
                    Text(verbatim: "Toca un perfil para activarlo directamente sin pasar por el asistente.").font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Diagnóstico")
        }
    }
}

// =====================================================================
// MARK: - TAB CABINA
// =====================================================================
struct CabinaView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                BannerConexion(pilot: pilot)
                BotonesStop(pilot: pilot)
                seccionGas
                seccionMantener
                seccionDespegue
                seccionPulsos
                seccionDireccion
                seccionAjustesMandos
            }
            .navigationTitle("BluHeli \(HeliPilot.versionApp)")
        }
    }

    var seccionGas: some View {
        Section(header: Text(verbatim: "GAS").bold()) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(verbatim: "Objetivo").bold(); Spacer(); Text(verbatim: "\(Int(pilot.gasObjetivo)) %").font(.title2).bold().foregroundColor(pilot.gasObjetivo > 0 ? .orange : .secondary) }
                HStack { Text(verbatim: "Enviado").bold(); Spacer()
                    Text(verbatim: "\(Int(pilot.gasEnviado)) % · rotor \(pilot.rotorDe(pilot.gasEnviado))/\(pilot.perfilEnUso.rotorMax)").font(.title3).bold()
                        .foregroundColor(pilot.gasEnviado > 0 ? (pilot.gasEnviado > 60 ? .red : .green) : .secondary) }
                Slider(value: $pilot.gasObjetivo, in: 0...100, step: 1).tint(pilot.gasObjetivo > 0 ? .orange : .gray).disabled(pilot.maniobraActiva)
            }
            Toggle(isOn: $pilot.modoSalon) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Modo salón (tope \(Int(pilot.topeSalon)) %)").bold()
                    Text(verbatim: "Desactívalo solo en exterior.").font(.caption2).foregroundColor(.secondary)
                }
            }.tint(.green)
            Text(verbatim: "Batería: se lee en tiempo real de la respuesta del heli mientras está encendido y conectado. Con el interruptor en OFF‑CHG el heli está apagado y no emite, así que la carga no se puede ver desde la app: mira el LED del cargador.")
                .font(.caption2).foregroundColor(.secondary)
            Toggle(isOn: $pilot.armadoActivo) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Armado previo (0,4 s a rotor 0 antes de subir)").bold()
                    Text(verbatim: "Si el heli tarda en responder al primer gas, déjalo activado.").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    var seccionMantener: some View {
        Section(header: Text(verbatim: "MANTENER PARA VOLAR (suelta = gas 0)").bold()) {
            HStack {
                Text(verbatim: "Potencia").bold()
                Slider(value: $pilot.potenciaMantener, in: 10...100, step: 1)
                Text(verbatim: "\(Int(pilot.potenciaMantener)) %").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
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
                Button(action: { pilot.despegueSuave() }) { HStack { Spacer(); Image(systemName: "arrow.up.circle.fill"); Text(verbatim: "🛫 DESPEGAR").bold(); Spacer() } }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(pilot.maniobraActiva || !pilot.conectado)
                Button(action: { pilot.aterrizarSuave() }) { HStack { Spacer(); Image(systemName: "arrow.down.circle.fill"); Text(verbatim: "🛬 ATERRIZAR").bold(); Spacer() } }
                    .buttonStyle(.bordered).tint(.blue).disabled(pilot.gasObjetivo <= 0 || pilot.maniobraActiva)
            }
            .padding(.vertical, 4)
        }
    }

    var seccionPulsos: some View {
        Section(header: Text(verbatim: "PULSOS DE PRUEBA (2 s, sujeta el heli)")) {
            Button(action: { pilot.ejecutarPulso(potencia: 30) }) { Text(verbatim: "⚡ 30 % — ¿giran las palas?") }
            Button(action: { pilot.ejecutarPulso(potencia: 45) }) { Text(verbatim: "⚡ 45 % — sustentación baja") }
            Button(action: { pilot.ejecutarPulso(potencia: 60) }) { Text(verbatim: "⚡ 60 % — vuelo salón") }
            Picker(selection: $pilot.rampaPorTick) {
                Text(verbatim: "Rampa suave").tag(1.5); Text(verbatim: "Normal").tag(2.5); Text(verbatim: "Rápida").tag(5.0)
            } label: { Text(verbatim: "Rampa de gas") }
            .pickerStyle(.segmented)
        }
        .disabled(pilot.maniobraActiva || !pilot.conectado)
    }

    var seccionDireccion: some View {
        Section(header: Text(verbatim: "DIRECCIÓN").bold()) {
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Pitch (atrás 0 · adelante 255)").bold(); Spacer(); Text(verbatim: "\(Int(pilot.pitch))").font(.caption) }
                Slider(value: $pilot.pitch, in: 0...255, step: 1, onEditingChanged: { e in if !e && pilot.autoCentrar { pilot.pitch = 127 } })
            }
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Yaw (izq 0 · der 255)").bold(); Spacer(); Text(verbatim: "\(Int(pilot.yaw))").font(.caption) }
                Slider(value: $pilot.yaw, in: 0...255, step: 1, onEditingChanged: { e in if !e && pilot.autoCentrar { pilot.yaw = 127 } })
            }
            Toggle(isOn: $pilot.autoCentrar) { Text(verbatim: "Auto‑centrar al soltar (sliders)") }
            Stepper(value: $pilot.trim, in: 0...pilot.perfilEnUso.trimMax) { Text(verbatim: "Trim: \(pilot.trim) (neutro \(pilot.perfilEnUso.trimNeutro))") }
            Stepper(value: $pilot.perfilActivo.luz, in: 0...7) { Text(verbatim: "Luz: \(pilot.perfilActivo.luz)  (prueba valores: la app oficial usaba 4 por defecto)") }
            Picker(selection: $pilot.match) {
                Text(verbatim: "A").tag(0); Text(verbatim: "B").tag(1); Text(verbatim: "C").tag(2); Text(verbatim: "D").tag(3)
            } label: { Text(verbatim: "Canal") }
            .pickerStyle(.segmented)
        }
    }

    var seccionAjustesMandos: some View {
        Section(header: Text(verbatim: "MANDOS DE LA PESTAÑA VUELO").bold()) {
            Toggle(isOn: $pilot.modoFacil) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Modo fácil").bold()
                    Text(verbatim: "Botones grandes de dirección (mantener = mover, soltar = centrar) en vez de joystick, curva suave y botón HOVER con el gas memorizado.").font(.caption2).foregroundColor(.secondary)
                }
            }.tint(.green)
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Gas de HOVER").bold(); Spacer(); Text(verbatim: "\(Int(pilot.gasHover)) %").font(.caption) }
                Slider(value: $pilot.gasHover, in: 10...100, step: 1)
                Text(verbatim: "El gas con el que el heli se queda quieto en el aire. Se afina en vuelo con − / + y se recuerda. Baja con la batería.").font(.caption2).foregroundColor(.secondary)
            }
            Toggle(isOn: $pilot.gasSpring) {
                VStack(alignment: .leading) {
                    Text(verbatim: "Palanca de gas: al soltar → 0").bold()
                    Text(verbatim: "Apagado = se queda donde la dejas, como un mando RC.").font(.caption2).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading) {
                HStack { Text(verbatim: "Sensibilidad del joystick").bold(); Spacer(); Text(verbatim: "\(Int(pilot.sensibilidad * 100)) %").font(.caption) }
                Slider(value: $pilot.sensibilidad, in: 0.3...1.0, step: 0.05)
            }
            Toggle(isOn: $pilot.invertirYaw) { Text(verbatim: "Invertir yaw") }
            Toggle(isOn: $pilot.invertirPitch) { Text(verbatim: "Invertir pitch") }
        }
    }
}

struct BotonMantener: View {
    @ObservedObject var pilot: HeliPilot
    @State private var pulsado = false

    var body: some View {
        let activo = pilot.conectado && !pilot.maniobraActiva
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(!activo ? Color.gray.opacity(0.35) : (pulsado ? Color.red : Color.orange))
            VStack(spacing: 4) {
                Image(systemName: pulsado ? "flame.fill" : "hand.tap.fill").font(.title)
                Text(verbatim: pulsado ? "VOLANDO · SUELTA PARA PARAR" : "MANTENER PULSADO PARA VOLAR").font(.headline).bold()
                Text(verbatim: "\(Int(pilot.potenciaMantener)) % · rotor \(pilot.rotorDe(pilot.potenciaMantener))").font(.caption)
            }
            .foregroundColor(.white).padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, pressing: { presionando in
            guard activo else { return }
            pulsado = presionando
            pilot.mantener(presionando)
        }, perform: {})
        .onDisappear { if pulsado { pulsado = false; pilot.mantener(false) } }
    }
}

// =====================================================================
// MARK: - TAB PROTOCOLO (todo editable)
// =====================================================================
struct AjustesView: View {
    @ObservedObject var pilot: HeliPilot

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(verbatim: "PANEL EXPERTO")) {
                    Text(verbatim: "No hace falta tocar nada aquí: el perfil correcto ya está activo y guardado. Esta pestaña sirve para ver la trama exacta que sale, lo que responde el heli y, si algún día cambia algo, ajustar cualquier detalle del protocolo sin recompilar.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section(header: Text(verbatim: "TRAMA EN VIVO")) {
                    Text(verbatim: pilot.tramaVisible.isEmpty ? Codificador.trama(perfil: pilot.perfilEnUso, rotor: 0, pitch: 127, yaw: 127, trim: pilot.trim, match: pilot.match).visible : pilot.tramaVisible)
                        .font(.system(.body, design: .monospaced)).foregroundColor(.blue)
                    Text(verbatim: "Bytes: " + pilot.tramaActual().bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    HStack {
                        Text(verbatim: "RX texto").foregroundColor(.secondary); Spacer()
                        Text(verbatim: pilot.rxTexto.isEmpty ? "--" : pilot.rxTexto).font(.system(.caption, design: .monospaced)).foregroundColor(.purple).lineLimit(2)
                    }
                    HStack {
                        Text(verbatim: "RX hex").foregroundColor(.secondary); Spacer()
                        Text(verbatim: pilot.rxHex.isEmpty ? "--" : pilot.rxHex).font(.system(.caption2, design: .monospaced)).foregroundColor(.purple).lineLimit(2)
                    }
                    if let n = pilot.rxNivel {
                        Text(verbatim: "Decodificado: respuesta 'x' + nivel \(n) (168 = lleno, baja con la carga del motor) → batería \(pilot.bateriaPorcentaje ?? 0) % · flag \(pilot.rxFlag)").font(.caption)
                    }
                }

                Section(header: Text(verbatim: "PERFIL ACTIVO: \(pilot.perfilActivo.nombre)"),
                        footer: Text(verbatim: "Cualquier cambio se aplica al instante a la trama y se guarda. Los valores por defecto son los del binario oficial.")) {
                    Picker(selection: Binding(get: { pilot.perfilActivo.id }, set: { id in
                        if let p = Perfil.candidatos.first(where: { $0.id == id }) { pilot.perfilActivo = p; pilot.trim = p.trimNeutro }
                    })) {
                        ForEach(Perfil.candidatos) { p in Text(verbatim: p.nombre).tag(p.id) }
                    } label: { Text(verbatim: "Cargar preset") }

                    Toggle(isOn: $pilot.perfilActivo.texto) { Text(verbatim: "Trama en texto ASCII hex (oficial)") }
                    Picker(selection: $pilot.perfilActivo.layout) {
                        Text(verbatim: "Silverlit (5 bytes)").tag(Layout.silverlit)
                        Text(verbatim: "WeCCAN (6 bytes)").tag(Layout.weccan)
                    } label: { Text(verbatim: "Mapa de campos") }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(verbatim: "Cabecera")
                        TextField("x", text: $pilot.perfilActivo.cabecera).multilineTextAlignment(.trailing).autocapitalization(.none).disableAutocorrection(true)
                    }
                    Toggle(isOn: $pilot.perfilActivo.mayusculas) { Text(verbatim: "Hex en mayúsculas") }
                    Picker(selection: $pilot.perfilActivo.terminador) {
                        Text(verbatim: "ninguno").tag(""); Text(verbatim: "\\r").tag("\r"); Text(verbatim: "\\n").tag("\n"); Text(verbatim: "\\r\\n").tag("\r\n")
                    } label: { Text(verbatim: "Terminador") }
                    Toggle(isOn: $pilot.perfilActivo.checksum) { Text(verbatim: "Añadir checksum (complemento a dos)") }
                    Toggle(isOn: $pilot.perfilActivo.ordenInverso) { Text(verbatim: "Binario WeCCAN: byte alto primero") }

                    Picker(selection: $pilot.perfilActivo.rotorMax) {
                        Text(verbatim: "0..128 (oficial)").tag(128); Text(verbatim: "0..255").tag(255)
                    } label: { Text(verbatim: "Rango de rotor") }
                    .pickerStyle(.segmented)

                    Stepper(value: $pilot.perfilActivo.luz, in: 0...15) { Text(verbatim: "Luz: \(pilot.perfilActivo.luz)  (oficial mid 4 · máx 7)") }
                    Stepper(value: $pilot.perfilActivo.nibbleBajo, in: 0...15) { Text(verbatim: "WeCCAN nibble bajo byte 0: \(pilot.perfilActivo.nibbleBajo)") }
                    Stepper(value: $pilot.perfilActivo.trimMax, in: 1...255) { Text(verbatim: "Trim máximo: \(pilot.perfilActivo.trimMax)") }
                    Stepper(value: $pilot.perfilActivo.trimNeutro, in: 0...255) { Text(verbatim: "Trim neutro: \(pilot.perfilActivo.trimNeutro)") }
                    Toggle(isOn: Binding(get: { pilot.perfilActivo.flagsFijos != nil }, set: { on in pilot.perfilActivo.flagsFijos = on ? 0x2A : nil })) {
                        Text(verbatim: "WeCCAN flags fijos 0x2A (Build 16) en vez de calculados")
                    }
                }

                Section(header: Text(verbatim: "ENLACE")) {
                    Stepper(value: $pilot.intervaloMs, in: 20...200, step: 10) { Text(verbatim: "Intervalo de envío: \(pilot.intervaloMs) ms (\(1000 / Swift.max(1, pilot.intervaloMs)) Hz)") }
                    Picker(selection: $pilot.match) {
                        Text(verbatim: "A").tag(0); Text(verbatim: "B").tag(1); Text(verbatim: "C").tag(2); Text(verbatim: "D").tag(3)
                    } label: { Text(verbatim: "Canal btMatch") }
                    .pickerStyle(.segmented)
                    HStack { Text(verbatim: "Protocolo MFi").foregroundColor(.secondary); Spacer(); Text(verbatim: pilot.protoActivo.isEmpty ? "--" : pilot.protoActivo).font(.caption) }
                    Button(action: { pilot.abrirSelectorBluetoothMFi() }) { Text(verbatim: "📲 Selector Bluetooth MFi") }
                    Button(action: { pilot.buscarYConectarAuto() }) { Text(verbatim: "🔄 Reconectar") }
                    Button(action: { pilot.cerrarSesion() }) { Text(verbatim: "✂️ Cerrar sesión MFi").foregroundColor(.red) }
                }

                Section(header: Text(verbatim: "CONSOLA")) {
                    TextEditor(text: $pilot.log).font(.system(.caption, design: .monospaced)).frame(minHeight: 260)
                    HStack {
                        Button(action: { UIPasteboard.general.string = pilot.log; pilot.agregarLog("Copiado al portapapeles.") }) { Text(verbatim: "Copiar registro") }
                        Spacer()
                        Button(action: { pilot.log = "" }) { Text(verbatim: "Limpiar").foregroundColor(.red) }
                    }
                }

                Section(header: Text(verbatim: "REFERENCIA (binario oficial sHelicopter 2011)")) {
                    Text(verbatim: "Trama = \"x\" + %llx del entero de 40 bits, relleno a 10 dígitos, UTF-8, sin checksum ni terminador. 20 Hz.")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(verbatim: "bits 0-4 trim (0..20) · 5-7 luz · 8-15 yaw · 16-23 pitch · 24-31 rotor (0..128) · 38-39 canal")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(verbatim: "Neutro canal B, gas 0: x40007f7f8a").font(.system(.caption, design: .monospaced))
                    Text(verbatim: "Respuesta observada: 4 bytes 78 NN FF 00 = 'x' + nivel de batería (múltiplo de 7, 168 lleno) + flag + 0").font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Protocolo")
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
                    TextEditor(text: $pilot.log).font(.system(.caption, design: .monospaced)).frame(minHeight: 380)
                    HStack {
                        Button(action: { UIPasteboard.general.string = pilot.log; pilot.agregarLog("Copiado al portapapeles.") }) { Text(verbatim: "Copiar registro") }
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
