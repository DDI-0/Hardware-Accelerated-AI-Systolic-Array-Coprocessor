// Host-only tests of plan generation, statistics, reproducible data, and result handling.
#include "gemm_suite.hpp"
#include <cassert>
#include <set>
#include <sstream>

static void reference(int m, int k, int n, const int8_t* a, const int8_t* b, int32_t* c) {
    for (int r = 0; r < m; ++r) for (int col = 0; col < n; ++col) {
        int64_t sum = 0;
        for (int z = 0; z < k; ++z) sum += int64_t(a[r*k+z]) * b[z*n+col];
        c[r*n+col] = static_cast<int32_t>(sum);
    }
}

struct FakeDriver {
    int calls = 0;
    bool corrupt = false, timeout = false, bad_counts = false;
    bool run_tiled_gemm(int m, int k, int n, const int8_t* a, const int8_t* b, int32_t* c,
                        uint64_t& cycles, GemmTimings& timings, int, bool verbose) {
        ++calls;
        assert(!verbose);
        if (timeout) return false;
        std::fill(c, c + m*n, 0);
        for (int z = 0; z < k; ++z) for (int r = 0; r < m; ++r) for (int col = 0; col < n; ++col)
            c[r*n+col] += int32_t(a[r*k+z]) * int32_t(b[z*n+col]);
        if (corrupt) ++c[0];
        timings = {};
        timings.steps = uint64_t((m+15)/16) * ((k+15)/16) * ((n+15)/16);
        timings.output_tiles = uint64_t((m+15)/16) * ((n+15)/16);
        if (bad_counts) ++timings.steps;
        cycles = timings.steps * 64;
        return true;
    }
};

static std::vector<std::vector<std::string>> read_csv(const std::string& path) {
    std::ifstream f(path);
    assert(f.good());
    std::vector<std::vector<std::string>> rows;
    std::string line;
    while (std::getline(f,line)) {
        std::vector<std::string> fields;
        std::istringstream stream(line);
        std::string value;
        while (std::getline(stream,value,',')) fields.push_back(value);
        if (!line.empty() && line.back()==',') fields.emplace_back();
        rows.push_back(fields);
    }
    return rows;
}

int main(int argc, char** argv) {
    assert(argc == 2); // Fresh existing output directory, provided by the test command.
    const std::string root = argv[1];
    std::vector<double> values;
    for (int i=1;i<=30;++i) values.push_back(i);
    assert(gemm_suite::median(values)==15.5);
    assert(gemm_suite::p95(values)==29);
    assert(gemm_suite::median({9,1,5})==5);
    assert(gemm_suite::p95({4})==4);
    bool threw=false;
    try { gemm_suite::median({}); } catch (const std::invalid_argument&) { threw=true; }
    assert(threw);

    const auto all=gemm_suite::cases("all");
    assert(all.size()==108);
    assert(gemm_suite::cases("repeat").size()==3);
    assert(gemm_suite::cases("correctness").size()==36);
    assert(gemm_suite::cases("boundary").size()==36);
    assert(gemm_suite::cases("scaling").size()==33);
    const auto large=gemm_suite::cases("large");
    assert(large.size()==4);
    for (size_t i=0; i<large.size(); ++i) {
        const int size=256*static_cast<int>(i+1);
        assert(large[i].m==size && large[i].k==size && large[i].n==size);
        const auto g=gemm_suite::geometry(large[i]);
        assert(g.padding_efficiency==1 && g.useful_ops==2ULL*size*size*size);
    }
    const auto largest=gemm_suite::geometry(large.back());
    assert(largest.steps==262144 && largest.outputs==4096);
    assert(largest.useful_ops==2147483648ULL);
    threw=false;
    try { gemm_suite::geometry({"invalid","unit","random",1025,1,1}); }
    catch (const std::invalid_argument&) { threw=true; }
    assert(threw);
    std::set<std::string> ids;
    for (const auto& c : all) {
        assert(ids.insert(c.id).second);
        const auto g=gemm_suite::geometry(c);
        assert(g.padding_efficiency>0 && g.padding_efficiency<=1);
        assert(g.useful_ops<=g.padded_ops);
        assert(g.input_bytes==g.steps*512 && g.output_bytes==g.outputs*1024);
    }
    const auto edge=gemm_suite::geometry({"edge","unit","random",17,33,19});
    assert(edge.steps==12 && edge.outputs==4 && edge.useful_ops==21318);
    assert(gemm_suite::geometry({"full","unit","random",16,16,16}).padding_efficiency==1);
    assert(gemm_suite::geometry({"17","unit","random",17,17,17}).steps==8);

    gemm_suite::Case c={"seeded","unit","random",64,64,64};
    std::vector<int8_t> a(4096),b(4096),a2(4096),b2(4096);
    gemm_suite::fill_inputs(c,123,a,b); gemm_suite::fill_inputs(c,123,a2,b2);
    assert(a==a2 && b==b2 && a!=b);
    const auto before=a;
    gemm_suite::fill_inputs(c,124,a,b); assert(a!=before);
    std::set<int> random_values(a.begin(),a.end()); assert(random_values.size()==256);
    for (const std::string pattern : {"negative","all_min","all_max","alternating","zero"}) {
        c.pattern=pattern; gemm_suite::fill_inputs(c,123,a,b);
        if (pattern=="negative") for (auto v:a) assert(v<0);
        if (pattern=="all_min") for (auto v:a) assert(v==-128);
        if (pattern=="all_max") for (auto v:a) assert(v==127);
        if (pattern=="zero") for (auto v:a) assert(v==0);
        if (pattern=="alternating") assert(std::set<int>(a.begin(),a.end())==std::set<int>({-128,127}));
    }
    assert(gemm_suite::case_seed(23063,"a",1)==gemm_suite::case_seed(23063,"a",1));
    assert(gemm_suite::case_seed(23063,"a",1)!=gemm_suite::case_seed(23063,"a",2));

    gemm_suite::Options options;
    options.output_prefix=root+"/pass";
    const std::vector<gemm_suite::Case> plan={{"small","unit","random",2,3,4},
                                            {"extreme","unit","all_min",1,256,1}};
    FakeDriver driver;
    assert(gemm_suite::run_cases(driver,options,plan,reference)==0);
    assert(driver.calls==66);
    const auto raw=read_csv(options.output_prefix+"_runs.csv");
    const auto summary=read_csv(options.output_prefix+"_summary.csv");
    assert(raw.size()==67 && summary.size()==3);
    int warmups=0,measured=0;
    for (size_t i=1;i<raw.size();++i) {
        assert(raw[i].size()==raw[0].size() && raw[i][9]=="PASS" && raw[i][10]=="0");
        raw[i][7]=="warmup" ? ++warmups : ++measured;
    }
    assert(warmups==6 && measured==60);
    for (size_t i=1;i<summary.size();++i) {
        assert(summary[i].size()==summary[0].size());
        assert(summary[i][6]=="PASS" && summary[i][11]=="30");
        assert(std::stod(summary[i][19])>0);
    }
    const int calls_before=driver.calls;
    assert(gemm_suite::run_cases(driver,options,plan,reference)==1); // Must not overwrite.
    assert(driver.calls==calls_before);
    for (const std::string failure : {"mismatch","timeout","counts"}) {
        options.output_prefix=root+"/"+failure;
        FakeDriver broken;
        broken.corrupt=failure=="mismatch"; broken.timeout=failure=="timeout"; broken.bad_counts=failure=="counts";
        assert(gemm_suite::run_cases(broken,options,plan,reference)==1 && broken.calls==1);
        const auto bad=read_csv(options.output_prefix+"_summary.csv");
        assert(bad.size()==2 && bad[1].size()==bad[0].size() && bad[1][6]=="FAIL" && bad[1][11]=="0");
        const auto bad_raw=read_csv(options.output_prefix+"_runs.csv");
        assert(bad_raw.size()==2 && bad_raw[1][9]=="FAIL");
    }
    std::cout << "PASS: statistics, 108-point plan, seeded signed patterns, geometry, 30-run CSV export,\n"
                 "warmup exclusion, overwrite protection, and fail-fast error handling. No FPGA tested.\n";
}
