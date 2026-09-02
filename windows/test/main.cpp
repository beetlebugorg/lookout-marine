/* The Windows shell's test runner.
 *
 * One entry per suite, in the order the shell reaches for them: what the core
 * hands over, then what the shell writes down. Exit code 0 when every check
 * passed.
 *
 * These cover the shell's MODEL: the decoders, the geometry and the store.
 * What a mariner types and the strings a mariner reads are the core's format
 * kit, and the core tests them. The WinUI layer is not here either: it needs a
 * XAML host, and the point of this target is that everything a host is not
 * required for can be run by anyone with the compiler the core already needs.
 */
#include <cstdio>

#include "lk_test.h"

void TestJson();
void TestUtf8();
void TestPick();
void TestPickLayout();
void TestLicenses();
void TestPluginRegistry();
void TestAlerts();
void TestTable();
void TestPaths();

int main()
{
    std::printf("lookout-marine: the Windows shell\n\n");

    TestJson();
    TestUtf8();
    TestPick();
    TestPickLayout();
    TestLicenses();
    TestPluginRegistry();
    TestAlerts();
    TestTable();
    TestPaths();

    return lktest::Report();
}
