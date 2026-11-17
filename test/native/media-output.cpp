#include "platform/shared/media/output_file.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;
using moojicut::media::OutputFile;
using moojicut::media::OutputKind;

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
static void write(const fs::path &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary);
    file << bytes;
    require(file.good(), "fixture write failed");
}
static std::string read(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);
    require(file.good(), "retained file is missing");
    return std::string(std::istreambuf_iterator<char>(file), {});
}
static void publish(const fs::path &partial, const fs::path &target) {
    require(!fs::exists(target), "target collision");
    fs::rename(partial, target);
}

int main(int argc, char **argv) {
    try {
        require(argc == 2, "provide an isolated temporary directory");
        fs::path root(argv[1]);
        fs::create_directories(root);
        // Capture/encoding/finalization errors must preserve whatever was written.
        fs::path failed = root / "capture.mp4", partial;
        try {
            OutputFile output(failed, OutputKind::Original);
            partial = output.partial();
            write(partial, "incomplete original bytes");
            throw std::runtime_error("simulated capture failure");
        } catch (const std::runtime_error &) {}
        require(read(partial) == "incomplete original bytes", "capture failure deleted original");
        require(!fs::exists(failed), "incomplete file was silently published");

        // Publishing a finalized original can fail; never replace an existing file.
        fs::path collision = root / "collision.mp4";
        write(collision, "existing target");
        bool rejected = false;
        {
            OutputFile output(collision, OutputKind::Original);
            partial = output.partial();
            write(partial, "finalized original bytes");
            try { output.publish(publish); } catch (const std::runtime_error &) { rejected = true; }
            require(!output.published() && output.retained() == partial, "failed publish reported wrong path");
        }
        require(rejected, "collision was accepted");
        require(read(partial) == "finalized original bytes", "rename failure deleted original");
        require(read(collision) == "existing target", "collision changed an existing target");

        // A decoder/probe failure after publication must retain/report the final path.
        fs::path saved = root / "saved.mp4", retained;
        try {
            OutputFile output(saved, OutputKind::Original);
            write(output.partial(), "saved original bytes");
            output.publish(publish);
            retained = output.retained();
            require(output.published(), "successful publish not recorded");
            throw std::runtime_error("simulated probe failure");
        } catch (const std::runtime_error &) {}
        require(retained == saved && read(saved) == "saved original bytes", "probe failure lost original");

        // Only derived intermediates are disposable; source and foreign target survive.
        fs::path derived = root / "preview.mp4";
        write(derived, "foreign export");
        {
            OutputFile output(derived, OutputKind::Derived);
            partial = output.partial();
            write(partial, "cancelled export bytes");
            try { output.publish(publish); } catch (const std::runtime_error &) {}
        }
        require(!fs::exists(partial), "failed derived output was not cleaned");
        require(read(derived) == "foreign export", "failed export changed foreign target");
        require(read(saved) == "saved original bytes", "export changed source");
        fs::path exported = root / "exported.mp4";
        {
            OutputFile output(exported, OutputKind::Derived);
            partial = output.partial();
            write(partial, "completed export bytes");
            output.publish(publish);
        }
        require(!fs::exists(partial) && read(exported) == "completed export bytes", "successful export was cleaned");
        std::cout << "Media output ownership checks passed.\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
