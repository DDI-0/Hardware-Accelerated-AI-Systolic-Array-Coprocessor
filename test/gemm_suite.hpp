#pragma once

#include "gemm_metrics.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace gemm_suite {

struct Options {
    std::string selection = "all";
    std::string output_prefix = "gemm_results";
    int runs = 30, warmup = 3, poll_us = 0;
    uint32_t seed = 23063;
};

struct Case {
    std::string id, group, pattern;
    int m, k, n;
};

struct Geometry {
    uint64_t useful_ops, padded_ops, steps, outputs, input_bytes, output_bytes;
    double padding_efficiency;
};

inline Geometry geometry(const Case& c) {
    if (c.m < 1 || c.k < 1 || c.n < 1 || c.m > 1024 || c.k > 1024 || c.n > 1024)
        throw std::invalid_argument("Suite dimensions must be in 1..1024");
    const uint64_t tm = (c.m + 15) / 16, tk = (c.k + 15) / 16, tn = (c.n + 15) / 16;
    const uint64_t useful = 2ULL * c.m * c.k * c.n;
    const uint64_t steps = tm * tk * tn, padded = steps * 8192;
    return {useful, padded, steps, tm * tn, steps * 512, tm * tn * 1024,
            static_cast<double>(useful) / static_cast<double>(padded)};
}

inline bool valid_selection(const std::string& s) {
    return s == "all" || s == "repeat" || s == "correctness" || s == "boundary" || s == "scaling" || s == "large";
}

inline std::vector<Case> cases(const std::string& selection) {
    if (!valid_selection(selection)) throw std::invalid_argument("Unknown suite selection");
    std::vector<Case> result;
    const auto add = [&](const std::string& group, const std::string& tag,
                         int m, int k, int n, const std::string& pattern = "random") {
        if (selection != "all" && selection != group) return;
        result.push_back({group + "_" + tag + "_" + std::to_string(m) + "x"
                          + std::to_string(k) + "x" + std::to_string(n) + "_" + pattern,
                          group, pattern, m, k, n});
    };
    // Explicit opt-in: keep the existing 108-point all suite unchanged.
    if (selection == "large") {
        for (int size : {256, 512, 768, 1024}) add("large", "square", size, size, size);
        return result;
    }
    for (int size : {64, 128, 256}) add("repeat", "square", size, size, size);
    const int correctness_shapes[][3] = {{1,1,1}, {7,19,23}, {17,33,19},
                                         {31,17,65}, {65,31,17}, {16,256,16}};
    for (const auto& shape : correctness_shapes)
        for (const std::string pattern : {"random", "negative", "all_min", "all_max", "alternating", "zero"})
            add("correctness", "signed", shape[0], shape[1], shape[2], pattern);
    for (int boundary : {16, 32, 64}) {
        for (int size : {boundary - 1, boundary, boundary + 1}) {
            add("boundary", "vary_m", size, 64, 64);
            add("boundary", "vary_k", 64, size, 64);
            add("boundary", "vary_n", 64, 64, size);
            add("boundary", "square", size, size, size);
        }
    }
    for (int k : {1,4,8,16,32,64,128,256}) add("scaling", "vary_k", 64, k, 64);
    for (int size : {1,8,16,32,64,128,256}) {
        add("scaling", "vary_m", size, 64, 64);
        add("scaling", "vary_n", 64, 64, size);
    }
    for (int size : {32,64,128,256}) add("scaling", "square", size, size, size);
    for (const auto& shape : {std::vector<int>{128,64,16}, {16,64,128}, {256,32,8}, {8,32,256}})
        add("scaling", "equal_work_shapes", shape[0], shape[1], shape[2]);
    for (const auto& shape : {std::vector<int>{63,65,64}, {64,65,63}, {65,64,63}})
        add("scaling", "irregular", shape[0], shape[1], shape[2]);
    return result;
}

inline uint32_t case_seed(uint32_t base, const std::string& id, uint32_t index) {
    // Stable hash and defined unsigned wraparound, independent of std::hash implementations.
    uint32_t hash = 2166136261U;
    for (unsigned char ch : id) hash = (hash ^ ch) * 16777619U;
    return base ^ hash ^ (index * 0x9E3779B9U);
}

inline void fill_inputs(const Case& c, uint32_t seed, std::vector<int8_t>& a, std::vector<int8_t>& b) {
    std::mt19937 rng(seed);
    const auto fill = [&](std::vector<int8_t>& values, bool matrix_b) {
        for (size_t i = 0; i < values.size(); ++i) {
            int value;
            if (c.pattern == "random") value = static_cast<int>(rng() & 255U) - 128;
            else if (c.pattern == "negative") value = -1 - static_cast<int>(rng() & 127U);
            else if (c.pattern == "all_min") value = -128;
            else if (c.pattern == "all_max") value = 127;
            else if (c.pattern == "alternating") {
                // Coordinate-dependent extremes prevent trivial parity cancellation across K.
                const size_t width = static_cast<size_t>(matrix_b ? c.n : c.k);
                value = ((i / width + i % width + (matrix_b ? 1 : 0)) % 3) ? -128 : 127;
            } else if (c.pattern == "zero") value = matrix_b ? static_cast<int>(rng() & 255U) - 128 : 0;
            else throw std::invalid_argument("Unknown input pattern");
            values[i] = static_cast<int8_t>(value);
        }
    };
    fill(a, false); fill(b, true);
}

inline double median(std::vector<double> values) {
    if (values.empty()) throw std::invalid_argument("Empty sample set");
    std::sort(values.begin(), values.end());
    const size_t mid = values.size() / 2;
    return values.size() % 2 ? values[mid] : (values[mid - 1] + values[mid]) / 2;
}

inline double p95(std::vector<double> values) {
    if (values.empty()) throw std::invalid_argument("Empty sample set");
    std::sort(values.begin(), values.end());
    return values[static_cast<size_t>(std::ceil(0.95 * values.size())) - 1];
}

struct Sample {
    double cpu_us = 0, wall_us = 0;
    uint64_t cycles = 0;
    GemmTimings timings;
};

inline void print_plan(const Options& o, const std::vector<Case>& plan) {
    std::cout << "[SUITE] " << plan.size() << " points, " << o.warmup << " warmups and "
              << o.runs << " measured runs per point; poll_us=" << o.poll_us << " seed=" << o.seed << '\n';
    for (const auto& c : plan) {
        const auto g = geometry(c);
        std::cout << c.id << " steps=" << g.steps << " output_tiles=" << g.outputs
                  << " padding_efficiency=" << std::fixed << std::setprecision(2)
                  << g.padding_efficiency * 100 << "%\n";
    }
}

inline void write_summary(std::ostream& out, const Case& c, const Options& o,
                          const std::vector<Sample>& samples, bool pass) {
    const auto g = geometry(c);
    out << c.id << ',' << c.group << ',' << c.m << ',' << c.k << ',' << c.n << ',' << c.pattern
        << ',' << (pass ? "PASS" : "FAIL") << ',' << o.seed << ',' << o.poll_us << ',' << o.warmup
        << ',' << o.runs << ',' << samples.size() << ',' << g.useful_ops << ',' << g.padded_ops
        << ',' << g.steps << ',' << g.outputs << ',' << g.padding_efficiency * 100
        << ',' << g.input_bytes << ',' << g.output_bytes;
    if (samples.empty()) { out << ",,,,,,,,,,,,\n"; return; }
    std::vector<double> wall, cpu, cycles, reset, pack, submit, wait, decode, other;
    for (const auto& s : samples) {
        wall.push_back(s.wall_us); cpu.push_back(s.cpu_us); cycles.push_back(static_cast<double>(s.cycles));
        reset.push_back(s.timings.reset_us); pack.push_back(s.timings.pack_us);
        submit.push_back(s.timings.submit_us); wait.push_back(s.timings.wait_us); decode.push_back(s.timings.decode_us);
        other.push_back(s.wall_us - s.timings.reset_us - s.timings.pack_us - s.timings.submit_us
                        - s.timings.wait_us - s.timings.decode_us);
    }
    const double med = median(wall);
    out << ',' << med << ',' << p95(wall) << ',' << *std::max_element(wall.begin(), wall.end())
        << ',' << static_cast<double>(g.useful_ops) / (med * 1000.0) << ',' << median(cpu)
        << ',' << median(cycles) << ',' << median(reset) << ',' << median(pack) << ',' << median(submit)
        << ',' << median(wait) << ',' << median(decode) << ',' << median(other) << '\n';
}

// Driver and reference are injected so this suite can be tested without /dev/mem.
template<class Driver, class Reference>
int run_cases(Driver& driver, const Options& o, const std::vector<Case>& plan, Reference reference) {
    if (o.runs < 1 || o.runs > 1000 || o.warmup < 0 || o.warmup > 100
        || o.poll_us < 0 || o.poll_us > 1000 || plan.empty() || o.output_prefix.empty()) {
        std::cerr << "Invalid suite options or empty plan.\n"; return 1;
    }
    const std::string raw_path = o.output_prefix + "_runs.csv";
    const std::string summary_path = o.output_prefix + "_summary.csv";
    const std::string manifest_path = o.output_prefix + "_manifest.txt";
    for (const auto& path : {raw_path, summary_path, manifest_path}) {
        if (std::ifstream(path).good()) {
            std::cerr << "Results already exist: " << path << "; choose a new --output-prefix.\n";
            return 1;
        }
    }
    std::ofstream raw(raw_path), summary(summary_path), manifest(manifest_path);
    if (!raw || !summary || !manifest) {
        std::cerr << "Cannot create suite results. The output directory must already exist.\n"; return 1;
    }
    raw << std::fixed << std::setprecision(6);
    summary << std::fixed << std::setprecision(6);
    manifest << "suite=" << o.selection << "\nbuild=" << __DATE__ << ' ' << __TIME__
             << "\ncompiler=" << __VERSION__ << "\npoints=" << plan.size()
             << "\nruns=" << o.runs << "\nwarmup=" << o.warmup << "\nseed=" << o.seed
             << "\npoll_us=" << o.poll_us << "\nstatus=STARTED\n"
             << "wall_timer=steady_clock around run_tiled_gemm; includes packing/reset/DMA/waits/readback\n"
             << "excluded=generation, allocations, CPU reference, verification, console and CSV writes\n"
             << "p95=nearest rank ceil(0.95*N), median=mean of middle pair for even N\n"
             << "useful_gops=2*M*K*N/(median_wall_us*1000)\n"
             << "padding_efficiency=useful_ops/(tile_steps*8192); not hardware utilization\n"
             << "stage_medians_are_independent_and_need_not_sum_to_median_wall\n"
             << "cycles=PE reset/compute/flush counter; assumed configured fabric clock 100 MHz\n"
             << "inputs=new deterministic seed each invocation, including excluded warmups\n"
             << "cpu_reference=simple scalar loop, not optimized BLAS\n";
    manifest.flush();
    raw << "case_id,group,M,K,N,pattern,seed,phase,iteration,status,mismatches,cpu_us,wall_us,"
           "hw_cycles,useful_gops,tile_steps,output_tiles,padding_efficiency_pct,reset_us,packing_us,"
           "submission_us,wait_us,readback_us,other_us\n";
    summary << "case_id,group,M,K,N,pattern,status,base_seed,poll_us,warmup_runs,requested_runs,"
               "passed_measured_runs,useful_ops,padded_ops,tile_steps,output_tiles,padding_efficiency_pct,"
               "input_bytes,output_bytes,median_wall_us,p95_wall_us,max_wall_us,useful_gops_at_median,"
               "median_cpu_us,median_hw_cycles,median_reset_us,median_packing_us,median_submission_us,"
               "median_wait_us,median_readback_us,median_other_us\n";
    raw.flush(); summary.flush();
    if (!raw || !summary || !manifest) {
        std::cerr << "Cannot write suite headers; no test transfers started.\n"; return 1;
    }
    using Clock = std::chrono::steady_clock;
    for (size_t point = 0; point < plan.size(); ++point) {
        const auto& c = plan[point];
        const auto g = geometry(c);
        std::cout << "[SUITE] " << point + 1 << '/' << plan.size() << ' ' << c.id << std::endl;
        std::vector<int8_t> a(static_cast<size_t>(c.m) * c.k), b(static_cast<size_t>(c.k) * c.n);
        std::vector<int32_t> expected(static_cast<size_t>(c.m) * c.n), actual(expected.size());
        std::vector<Sample> samples;
        for (int invocation = 0; invocation < o.warmup + o.runs; ++invocation) {
            const bool warmup = invocation < o.warmup;
            const int iteration = warmup ? invocation + 1 : invocation - o.warmup + 1;
            const uint32_t seed = case_seed(o.seed, c.id, static_cast<uint32_t>(invocation));
            fill_inputs(c, seed, a, b);
            std::fill(actual.begin(), actual.end(), INT32_MIN);
            Sample s;
            const auto cpu_start = Clock::now();
            // K<=1024: the worst INT8 dot product is 1024*16384, safely inside INT32.
            reference(c.m, c.k, c.n, a.data(), b.data(), expected.data());
            s.cpu_us = std::chrono::duration<double,std::micro>(Clock::now() - cpu_start).count();
            const auto start = Clock::now();
            const bool completed = driver.run_tiled_gemm(c.m, c.k, c.n, a.data(), b.data(), actual.data(),
                                                         s.cycles, s.timings, o.poll_us, false);
            s.wall_us = std::chrono::duration<double,std::micro>(Clock::now() - start).count();
            int mismatches = completed ? 0 : -1;
            if (completed) {
                for (size_t i = 0; i < actual.size(); ++i) {
                    if (actual[i] != expected[i]) {
                        if (mismatches < 8) std::cerr << "[MISMATCH] " << c.id << " seed=" << seed
                            << " row=" << i / c.n << " col=" << i % c.n
                            << " expected=" << expected[i] << " got=" << actual[i] << '\n';
                        ++mismatches;
                    }
                }
            }
            const bool pass = completed && mismatches == 0 && s.timings.steps == g.steps
                              && s.timings.output_tiles == g.outputs;
            const double other = s.wall_us - s.timings.reset_us - s.timings.pack_us
                                 - s.timings.submit_us - s.timings.wait_us - s.timings.decode_us;
            raw << c.id << ',' << c.group << ',' << c.m << ',' << c.k << ',' << c.n << ',' << c.pattern
                << ',' << seed << ',' << (warmup ? "warmup" : "measured") << ',' << iteration
                << ',' << (pass ? "PASS" : "FAIL") << ',' << mismatches << ',' << s.cpu_us << ',' << s.wall_us
                << ',' << s.cycles << ',' << static_cast<double>(g.useful_ops) / (s.wall_us * 1000.0)
                << ',' << s.timings.steps << ',' << s.timings.output_tiles << ',' << g.padding_efficiency * 100
                << ',' << s.timings.reset_us << ',' << s.timings.pack_us << ',' << s.timings.submit_us
                << ',' << s.timings.wait_us << ',' << s.timings.decode_us << ',' << other << '\n';
            raw.flush();
            if (!pass || !raw) {
                write_summary(summary, c, o, samples, false); summary.flush();
                manifest << "final_status=FAIL\nfailed_case=" << c.id << "\nfailed_seed=" << seed << '\n';
                manifest.flush();
                std::cerr << "Suite stopped: mismatch, incomplete transfer, counter discrepancy, or output write error.\n";
                return 1;
            }
            if (!warmup) samples.push_back(s);
        }
        write_summary(summary, c, o, samples, true); summary.flush();
        if (!summary) { std::cerr << "Summary write failed.\n"; return 1; }
        std::vector<double> wall;
        for (const auto& s : samples) wall.push_back(s.wall_us);
        std::cout << "[PASS] " << o.runs << " measured runs; median=" << median(wall)
                  << " us p95=" << p95(wall) << " us max=" << *std::max_element(wall.begin(),wall.end())
                  << " us" << std::endl;
    }
    manifest << "final_status=PASS\n"; manifest.flush();
    if (!manifest) { std::cerr << "Manifest write failed.\n"; return 1; }
    std::cout << "[SUITE] PASS. Saved " << raw_path << ", " << summary_path << ", " << manifest_path << '\n';
    return 0;
}

template<class Driver, class Reference>
int run(Driver& driver, const Options& o, Reference reference) {
    return run_cases(driver, o, cases(o.selection), reference);
}

} // namespace gemm_suite
