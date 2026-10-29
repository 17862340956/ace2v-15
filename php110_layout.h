/* SPDX-License-Identifier: GPL-2.0 */
#ifndef PHP110_LAYOUT_H
#define PHP110_LAYOUT_H
/* QILIN_SOURCE_ROOT is defined by Kbuild to the pinned 901 source tree. */
#include <internal.h>
#ifdef CONFIG_GCC_PLUGIN_RANDSTRUCT
#error "Randomized private layouts require an exact matching layout seed"
#endif
#ifdef CONFIG_RANDSTRUCT_FULL
#error "Randomized private layouts require exact matching layout evidence"
#endif
static_assert(offsetof(struct proc_inode, pde) < offsetof(struct proc_inode, vfs_inode));
static_assert(offsetof(struct proc_dir_entry, proc_ops) < sizeof(struct proc_dir_entry));
#endif
