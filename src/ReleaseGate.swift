// ============================================================
// 换模型前的「真的把内存还回来」闸门（M1b · 2026-10-31）
// ============================================================
//
// 背景：`stop()` 原来只做两件事——跑停止命令、等端口释放。端口死了不等于内存回来了：
// 复盘实测崩溃残骸态：端口释放后仍是大额 wired + compressor、空闲页见底。
// 于是「停旧的 → 起新的」之间缺一段可判定的等待，新模型落在旧残骸上，两个都起不来
// （用户看到的就是「一次拉起两个 27B」）。
//
// 四步，任何一步超时都要把「差多少 / 谁占着」写出来：
//   ① 停（调用方已执行：recipe.stop）
//   ② 端口释放
//   ③ 进程树清零（Splash 的 serve-native / Strata 的 server.py + strata-vision 都是子孙进程）
//   ④ 可用内存到位（口径复用 MemoryBudget：总 − wired − 压缩 − 已驻留 − 预留）
//
// 不做 `purge`：它要 root，而真正吃内存的是进程与 Metal/MPS 分配，不是文件缓存
// （复盘实测：进程树收干净后空闲页立刻回到绝大多数）。

import Foundation

enum ReleaseGate {
    struct Outcome {
        var ok: Bool
        var detail: String
        var freedGB: Double = 0
        var seconds: Double = 0
    }

    /// 当前可用于「再起一个模型」的 GB（口径与 MemoryBudget 一致）
    static func availableGB(reserveGB: Double, residentGB: Double = 0) -> Double {
        let s = MemorySampler()
        let r = s.next()
        let mm = s.last
        let b = MemoryBudget(totalGB: r.totalGB, usedGB: r.usedGB, reserveGB: reserveGB,
                             wiredGB: mm.wiredGB, compressedGB: mm.compressedGB,
                             modelResidentGB: residentGB)
        return b.availableGB
    }

    /// 端口上还有没有 LISTEN 的进程
    static func portBusy(_ port: Int) -> Bool {
        !listenerPids(port).isEmpty
    }

    static func listenerPids(_ port: Int) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { pid_t($0) }
    }

    static func waitPortFree(_ port: Int, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !portBusy(port) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !portBusy(port)
    }

    /// 等一组 pid 全部消失（调用方通常传监听进程的 pid；子孙进程由调用方一并列入）
    static func waitPidsGone(_ pids: [pid_t], timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return pids.allSatisfy({ kill($0, 0) != 0 })
    }

    /// 进程树里的全部 pid（含自己）
    static func processTree(_ root: pid_t) -> [pid_t] {
        var all: [pid_t] = [root]
        var i = 0
        while i < all.count {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", "\(all[i])"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { i += 1; continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                if let pid = pid_t(line), !all.contains(pid) { all.append(pid) }
            }
            i += 1
        }
        return all
    }

    /// 等可用内存回到 `atLeastGB`（或比 `baselineGB` 多出 `expectGB` 的九成）
    static func waitMemory(atLeast atLeastGB: Double, expectGB: Double, baselineGB: Double,
                           reserveGB: Double, timeout: Double) -> Outcome {
        let t0 = Date()
        var last = availableGB(reserveGB: reserveGB)
        let target = min(atLeastGB, baselineGB + max(0, expectGB) * 0.9)
        let deadline = t0.addingTimeInterval(timeout)
        while Date() < deadline {
            last = availableGB(reserveGB: reserveGB)
            if last >= target {
                return Outcome(ok: true,
                               detail: String(format: "可用 %.1f GB（目标 %.1f，基线 %.1f）",
                                              last, target, baselineGB),
                               freedGB: max(0, last - baselineGB),
                               seconds: Date().timeIntervalSince(t0))
            }
            Thread.sleep(forTimeInterval: 2.0)
        }
        last = availableGB(reserveGB: reserveGB)
        return Outcome(ok: false,
                       detail: String(format: "等内存超时：可用 %.1f GB，目标 %.1f GB（差 %.1f）",
                                      last, target, max(0, target - last)),
                       freedGB: max(0, last - baselineGB),
                       seconds: Date().timeIntervalSince(t0))
    }
}
