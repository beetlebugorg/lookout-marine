// winrt_glue.cpp — compile the cppwinrt/XAML generated TUs that this hand-
// authored command-line project doesn't auto-register for compilation (the VS
// project system normally does). One TU, with the PCH.
//
//   XamlTypeInfo.g.cpp   -> the XAML type table AND the aggregator that #includes
//                           App.xaml.g.hpp + MainWindow.xaml.g.hpp (the markup
//                           InitializeComponent impls), the wWinMain entry point
//                           and the VSDesigner exports. The single home for all
//                           of those — so the code-behind TUs must NOT also
//                           include the .xaml.g.hpp (that would duplicate them).
//   XamlTypeInfo.Impl.g.cpp -> XamlMetaDataProvider::GetXamlType/GetXmlnsDefinitions.
//   XamlMetaDataProvider.g.cpp -> its cppwinrt factory.
//   module.g.cpp         -> WINRT_GetActivationFactory / WINRT_CanUnloadNow
//                           (referenced by the VSDesigner stubs) + the activation
//                           dispatcher. It has no wWinMain/VSDesigner of its own,
//                           so it doesn't clash.
#include "pch.h"

#if __has_include("XamlTypeInfo.g.cpp")
#include "XamlTypeInfo.g.cpp"
#endif
#if __has_include("XamlTypeInfo.Impl.g.cpp")
#include "XamlTypeInfo.Impl.g.cpp"
#endif
#if __has_include("XamlMetaDataProvider.g.h")
#include "XamlMetaDataProvider.g.h"
#endif
#if __has_include("XamlMetaDataProvider.g.cpp")
#include "XamlMetaDataProvider.g.cpp"
#endif
#if __has_include("module.g.cpp")
#include "module.g.cpp"
#endif
