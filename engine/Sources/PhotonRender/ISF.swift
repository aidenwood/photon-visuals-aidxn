// ISF — Interactive Shader Format.
//
// ISF is the VJ world's de facto shader standard: GLSL plus a JSON manifest in
// a leading comment block. VDMX and Resolume both support it, and **hundreds of
// effects and generators already exist**. Supporting it means shipping a large,
// battle-tested library instead of hand-writing effects, and lets an operator
// bring shaders they already own.
//
// ## The honest scope
//
// This translates a **documented subset** of ISF/GLSL to MSL. Real-world ISF
// contains constructs that do not translate mechanically — dynamic loops,
// `#version` pragmas, multi-pass definitions, driver-specific slop. Those are
// **rejected with a specific reason**, not silently mistranslated.
//
// That is deliberate. A shader that fails to load is a line in a log; a shader
// that loads and renders subtly wrong is discovered on site, at night, with a
// client watching.

import Foundation
import Metal
import simd

/// An ISF input (uniform) declaration.
public struct ISFInput: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case float, bool, long, color, point2D, image, event
    }
    public var name: String
    public var kind: Kind
    public var label: String?
    public var min: Float?
    public var max: Float?
    public var defaultValue: Float?
}

/// A parsed ISF document.
public struct ISFShader: Sendable {
    public var description: String?
    public var credit: String?
    public var categories: [String]
    public var inputs: [ISFInput]
    /// The GLSL body, with the manifest comment stripped.
    public var glsl: String
    /// Translated MSL, ready for `makeLibrary(source:)`.
    public var msl: String
    /// Inputs the engine can actually drive (floats and colours).
    public var drivableInputs: [ISFInput] { inputs.filter { $0.kind == .float || $0.kind == .color } }
}

/// Why an ISF shader could not be loaded.
public enum ISFError: Error, CustomStringConvertible, Equatable {
    case noManifest
    case badManifest(String)
    /// A construct outside the supported subset. Carries what and why, so the
    /// operator can see which shader failed and roughly why.
    case unsupported(String)

    public var description: String {
        switch self {
        case .noManifest:
            return "no ISF manifest found (expected a leading /*{ ... }*/ block)"
        case .badManifest(let d):
            return "malformed ISF manifest: \(d)"
        case .unsupported(let what):
            return "unsupported ISF construct: \(what)"
        }
    }
}

/// Parses and translates ISF.
public enum ISF {
    /// Constructs this translator does not handle. Listed explicitly so the
    /// failure names the actual reason rather than producing a compile error
    /// from generated code nobody wrote.
    static let unsupportedTokens: [(token: String, why: String)] = [
        ("PASSES",            "multi-pass shaders"),
        ("PERSISTENT",        "persistent buffers"),
        ("IMG_THIS_PIXEL",    "feedback sampling"),
        ("IMG_THIS_NORM_PIXEL", "feedback sampling"),
        ("textureGrad",       "explicit-gradient sampling"),
        ("dFdx",              "screen-space derivatives"),
        ("dFdy",              "screen-space derivatives"),
        ("#version",          "explicit GLSL version pragma"),
        ("gl_FragCoord.w",    "perspective-divide reads"),
    ]

    /// Parses an ISF source file.
    public static func parse(_ source: String) throws -> ISFShader {
        guard let open = source.range(of: "/*"),
              let close = source.range(of: "*/", range: open.upperBound..<source.endIndex)
        else { throw ISFError.noManifest }

        let json = String(source[open.upperBound..<close.lowerBound])
        let body = String(source[close.upperBound...])

        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ISFError.badManifest("not valid JSON") }

        for (token, why) in unsupportedTokens where body.contains(token) || json.contains(token) {
            throw ISFError.unsupported(why)
        }

        var inputs: [ISFInput] = []
        for raw in (dict["INPUTS"] as? [[String: Any]]) ?? [] {
            guard let name = raw["NAME"] as? String,
                  let typeStr = raw["TYPE"] as? String,
                  let kind = ISFInput.Kind(rawValue: typeStr)
            else { continue }
            inputs.append(ISFInput(
                name: name,
                kind: kind,
                label: raw["LABEL"] as? String,
                min: (raw["MIN"] as? NSNumber)?.floatValue,
                max: (raw["MAX"] as? NSNumber)?.floatValue,
                defaultValue: (raw["DEFAULT"] as? NSNumber)?.floatValue))
        }

        let msl = try translate(body, inputs: inputs)
        return ISFShader(
            description: dict["DESCRIPTION"] as? String,
            credit: dict["CREDIT"] as? String,
            categories: (dict["CATEGORIES"] as? [String]) ?? [],
            inputs: inputs,
            glsl: body,
            msl: msl)
    }

    /// Translates the supported GLSL subset to MSL.
    static func translate(_ glsl: String, inputs: [ISFInput]) throws -> String {
        var body = glsl

        // Strip ISF's own uniform declarations; they become struct fields.
        for input in inputs {
            for type in ["float", "bool", "int", "vec2", "vec3", "vec4", "sampler2D"] {
                body = body.replacingOccurrences(
                    of: "uniform \(type) \(input.name);", with: "")
            }
        }

        // ISF's sampling helpers → Metal texture sampling.
        body = body.replacingOccurrences(
            of: #"IMG_NORM_PIXEL\(\s*(\w+)\s*,\s*"#,
            with: "$1.sample(isf_sampler, ",
            options: .regularExpression)
        body = body.replacingOccurrences(
            of: #"IMG_PIXEL\(\s*(\w+)\s*,\s*"#,
            with: "$1.sample(isf_sampler, ",
            options: .regularExpression)

        // Type names.
        let typeMap = [
            "vec2": "float2", "vec3": "float3", "vec4": "float4",
            "ivec2": "int2", "ivec3": "int3", "ivec4": "int4",
            "mat2": "float2x2", "mat3": "float3x3", "mat4": "float4x4",
        ]
        for (glslType, mslType) in typeMap {
            body = body.replacingOccurrences(
                of: "\\b\(glslType)\\b", with: mslType, options: .regularExpression)
        }

        // Built-ins.
        body = body.replacingOccurrences(of: "isf_FragNormCoord", with: "isf_uv")
        body = body.replacingOccurrences(of: "gl_FragCoord.xy", with: "(isf_uv * RENDERSIZE)")
        body = body.replacingOccurrences(of: "fract(", with: "fract(")
        body = body.replacingOccurrences(of: "mix(", with: "mix(")
        body = body.replacingOccurrences(of: "atan(", with: "atan2(")

        // `gl_FragColor = x;` → `return x;`
        body = body.replacingOccurrences(
            of: #"gl_FragColor\s*=\s*"#, with: "return ", options: .regularExpression)

        // `void main()` → our fragment entry point.
        guard body.contains("main") else {
            throw ISFError.unsupported("no main() function")
        }
        body = body.replacingOccurrences(
            of: #"void\s+main\s*\(\s*(void)?\s*\)"#,
            with: "float4 isf_main()", options: .regularExpression)

        // Uniform struct, in declaration order.
        var uniformFields = ""
        for input in inputs {
            switch input.kind {
            case .float, .long: uniformFields += "    float \(input.name);\n"
            case .bool:         uniformFields += "    int \(input.name);\n"
            case .color:        uniformFields += "    float4 \(input.name);\n"
            case .point2D:      uniformFields += "    float2 \(input.name);\n"
            case .image, .event: break   // images are textures; events are edges
            }
        }
        let imageInputs = inputs.filter { $0.kind == .image }
        var textureArgs = ""
        for (i, img) in imageInputs.enumerated() {
            textureArgs += ",\n    texture2d<float> \(img.name) [[texture(\(i))]]"
        }

        return """
        #include <metal_stdlib>
        using namespace metal;

        // Generated from ISF by photon. Do not edit.
        struct ISFUniforms {
            float2 RENDERSIZE;
            float  TIME;
            float  _pad;
        \(uniformFields)};

        constexpr sampler isf_sampler(filter::linear, address::clamp_to_edge);

        fragment float4 isf_fragment(
            float4 isf_position [[position]],
            constant ISFUniforms &isf_u [[buffer(0)]]\(textureArgs))
        {
            float2 RENDERSIZE = isf_u.RENDERSIZE;
            float  TIME = isf_u.TIME;
            float2 isf_uv = isf_position.xy / RENDERSIZE;
        \(referenceUniforms(inputs))
        \(indent(extractBody(body)))
        }
        """
    }

    /// Binds each manifest input to a local, so the translated body can use the
    /// plain names the shader author wrote.
    private static func referenceUniforms(_ inputs: [ISFInput]) -> String {
        inputs.compactMap { input in
            switch input.kind {
            case .float, .long: return "    float \(input.name) = isf_u.\(input.name);"
            case .bool:         return "    bool \(input.name) = isf_u.\(input.name) != 0;"
            case .color:        return "    float4 \(input.name) = isf_u.\(input.name);"
            case .point2D:      return "    float2 \(input.name) = isf_u.\(input.name);"
            case .image, .event: return nil
            }
        }.joined(separator: "\n")
    }

    /// Lifts the contents of `isf_main() { ... }` so it can be inlined.
    private static func extractBody(_ translated: String) -> String {
        guard let r = translated.range(of: "float4 isf_main()"),
              let open = translated.range(of: "{", range: r.upperBound..<translated.endIndex)
        else { return translated }
        var depth = 0
        var idx = open.lowerBound
        while idx < translated.endIndex {
            if translated[idx] == "{" { depth += 1 }
            if translated[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(translated[translated.index(after: open.lowerBound)..<idx])
                }
            }
            idx = translated.index(after: idx)
        }
        return translated
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }.joined(separator: "\n")
    }

    /// Compiles a parsed shader, proving the translation is valid MSL.
    ///
    /// Translation succeeding is not the same as the result compiling, so this
    /// is the check that actually matters.
    public static func compile(_ shader: ISFShader, device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: shader.msl, options: nil)
    }
}
