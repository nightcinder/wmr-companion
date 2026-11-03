cmake_minimum_required(VERSION 3.22.1)

# Debug-only diagnostic harness for the VITURE Luma Ultra Carina C SDK.
#
# libglasses.so is proprietary and is not vendored. The harness therefore
# resolves its symbols with dlopen at runtime, so this library builds and links
# in CI without the SDK and reports a typed error when the SDK is absent.
project(wmr_carina_diag C)

add_library(wmr_carina_diag SHARED carina_diag.c)

target_compile_options(wmr_carina_diag PRIVATE -Wall -Wextra -Werror)
target_link_libraries(wmr_carina_diag PRIVATE log dl)
