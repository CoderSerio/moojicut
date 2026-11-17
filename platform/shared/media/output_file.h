#ifndef MOOJICUT_MEDIA_OUTPUT_FILE_H
#define MOOJICUT_MEDIA_OUTPUT_FILE_H

#include <filesystem>
#include <system_error>
#include <utility>

namespace moojicut::media {

enum class OutputKind { Original, Derived };

// Raw recordings are irreplaceable. Even an incomplete file may be recoverable;
// only disposable preview/export intermediates are automatically removed.
// The caller owns a fresh job directory/name and must not reuse another job's
// partial path. Publishing must fail instead of replacing an existing target.
class OutputFile {
public:
    OutputFile(std::filesystem::path target, OutputKind kind)
        : target_(std::move(target)), kind_(kind) {
        std::filesystem::path name("partial-");
        name += target_.filename().native();
        partial_ = target_.parent_path() / name;
    }
    OutputFile(const OutputFile &) = delete;
    OutputFile &operator=(const OutputFile &) = delete;

    ~OutputFile() {
        if (kind_ == OutputKind::Derived && !published_) {
            std::error_code ignored;
            std::filesystem::remove(partial_, ignored);
        }
    }

    const std::filesystem::path &partial() const { return partial_; }
    const std::filesystem::path &retained() const { return published_ ? target_ : partial_; }
    bool published() const { return published_; }

    template <typename Publish>
    void publish(Publish moveWithoutReplacing) {
        moveWithoutReplacing(partial_, target_);
        published_ = true;
    }

private:
    std::filesystem::path target_, partial_;
    OutputKind kind_;
    bool published_ = false;
};

} // namespace moojicut::media

#endif
