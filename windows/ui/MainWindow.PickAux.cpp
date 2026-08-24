// The files a picked feature points at, rather than carries: TXTDSC and
// NTXTDS name a text file, PICREP a picture (lookout_aux_file), shown inline
// in the pick report; a picture opens full size in the PictureViewer overlay.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <algorithm>

#include "lk_format.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using lkw::Brush;
using namespace lkw::chrome;

namespace
{
    // UTF-8 → hstring with a Latin-1 fallback (an aux text file is not
    // always well-formed UTF-8).
    hstring TextFromBytes(unsigned char const *bytes, size_t len)
    {
        std::string_view view{ (char const *)bytes, len };
        try
        {
            return to_hstring(view);
        }
        catch (hresult_error const &)
        {
            std::wstring wide;
            wide.reserve(len);
            for (unsigned char c : view)
                wide.push_back((wchar_t)c);
            return hstring{ wide };
        }
    }
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::AddAuxFileView(Controls::StackPanel const &into,
                                    std::string const &cell, hstring const &name)
    {
        unsigned char const *bytes = nullptr;
        size_t len = 0;
        char const *mime = nullptr;
        std::string name_utf8 = to_string(name);
        int found = lk_controller_aux_file(controller, cell.c_str(), name_utf8.c_str(),
                                           &bytes, &len, &mime);

        Controls::StackPanel box;
        box.Margin({ 16, 2, 16, 6 });
        box.Spacing(6);

        bool is_image = found && mime != nullptr && strncmp(mime, "image/", 6) == 0;
        Controls::StackPanel head;
        head.Orientation(Controls::Orientation::Horizontal);
        head.Spacing(6);
        Controls::FontIcon icon;
        icon.Glyph(is_image ? L"\uE8B9" : L"\uE8A5"); // photo / document
        icon.FontSize(12);
        icon.Foreground(Brush(Muted(DarkChrome())));
        head.Children().Append(icon);
        Controls::TextBlock file_name;
        file_name.Text(name);
        file_name.FontSize(11);
        file_name.Foreground(Brush(Muted(DarkChrome())));
        file_name.IsTextSelectionEnabled(true);
        head.Children().Append(file_name);
        box.Children().Append(head);

        if (!found)
        {
            Controls::TextBlock missing;
            missing.Text(L"The chart does not carry this file.");
            missing.FontSize(10);
            missing.Foreground(Brush(Muted(DarkChrome())));
            box.Children().Append(missing);
        }
        else if (is_image)
        {
            // The bytes belong to the engine until close; the decoder gets a
            // copy. Clicking the picture opens it full size.
            Controls::Image img;
            img.MaxHeight(340);
            img.Stretch(Media::Stretch::Uniform);
            img.HorizontalAlignment(HorizontalAlignment::Left);
            std::vector<uint8_t> copy(bytes, bytes + len);
            LoadAuxImage(img, std::move(copy), name);
            img.Tapped([this, img, name](auto &&, auto &&) {
                if (img.Source() != nullptr)
                    ShowPicture(img.Source(), name);
            });
            box.Children().Append(img);
        }
        else
        {
            // A caution is worth reading in full: no inner scroll view, the
            // report itself scrolls.
            Controls::Border sheet;
            sheet.Background(Brush(0x0D000000));
            sheet.CornerRadius({ 6, 6, 6, 6 });
            sheet.Padding({ 8, 6, 8, 6 });
            Controls::TextBlock text;
            text.Text(TextFromBytes(bytes, len));
            text.FontSize(11);
            text.FontFamily(Media::FontFamily{ L"Consolas" });
            text.Foreground(Brush(Ink(DarkChrome())));
            text.TextWrapping(TextWrapping::Wrap);
            text.IsTextSelectionEnabled(true);
            sheet.Child(text);
            box.Children().Append(sheet);
        }
        into.Children().Append(box);
    }

    fire_and_forget MainWindow::LoadAuxImage(Controls::Image image,
                                             std::vector<uint8_t> bytes, hstring name)
    {
        auto lifetime = get_strong();
        try
        {
            Windows::Storage::Streams::InMemoryRandomAccessStream stream;
            Windows::Storage::Streams::DataWriter writer{ stream.GetOutputStreamAt(0) };
            writer.WriteBytes(bytes);
            co_await writer.StoreAsync();
            writer.DetachStream();
            stream.Seek(0);
            Media::Imaging::BitmapImage bmp;
            co_await bmp.SetSourceAsync(stream);
            image.Source(bmp);
        }
        catch (hresult_error const &)
        {
            // An undecodable picture leaves the file-name row alone.
        }
    }

    void MainWindow::ShowPicture(Media::ImageSource const &src, hstring const &name)
    {
        PictureImage().Source(src);
        PictureImage().MaxWidth(std::max(200.0, Root().ActualWidth() * 0.9));
        PictureImage().MaxHeight(std::max(200.0, Root().ActualHeight() * 0.85));
        PictureName().Text(name);
        PictureViewer().Visibility(Visibility::Visible);
    }
}
