#include <stdint.h>
#include <stdio.h>
#include <scotch.h>

#include <netloc.h>
#include <private/netloc.h>

#define NETLOC_int int // TODO

static int compareint(void const *a, void const *b)
{
   const int *int_a = (const int *)a;
   const int *int_b = (const int *)b;
   return *int_a-*int_b;
}

static int build_subarch(SCOTCH_Arch *arch, int partition_idx, NETLOC_int num_nodes, netloc_node_t **node_list,
        SCOTCH_Arch *subarch)
{
    int ret;

    /* Build list of indices of nodes */
    NETLOC_int *node_idx = (NETLOC_int *)malloc(sizeof(NETLOC_int[num_nodes]));
    for (int n = 0; n < num_nodes; n++) {
       netloc_node_t *node = node_list[n];

       netloc_position_t pos = node->newtopo_positions[partition_idx];
       node_idx[n] = pos.idx;
    }

    /* Hack to avoid problem with unsorted node list in the subarch and scotch
     * FIXME TODO */
    qsort(node_idx, num_nodes, sizeof(*node_idx), compareint);

    ret = SCOTCH_archSub(subarch, arch, num_nodes, node_idx);
    if (ret != 0) {
        fprintf(stderr, "Error: SCOTCH_archSub failed\n");
    }

    return ret;
}


static int explicit_to_deco(netloc_explicit_t *explicit, netloc_partition_t *partition,
        int num_nodes, NETLOC_int *node_list,
        SCOTCH_Arch *arch, SCOTCH_Arch *subarch)
{
    assert(0); // TODO
    return 0;
}


static int tree_to_tleaf(netloc_topology_t *topology, SCOTCH_Arch *arch)
{
    int ret = SCOTCH_archTleaf(arch, topology->ndims, topology->dimensions, topology->costs);
    if (ret != 0) {
        fprintf(stderr, "Error: SCOTCH_archTleaf failed\n");
        return NETLOC_ERROR;
    }

    return 0;
}

int netlocscotch_export_topology(netloc_machine_t *machine,
        int partition_idx, int num_nodes, char **node_names,
        SCOTCH_Arch *arch, SCOTCH_Arch *subarch)
{
    netloc_partition_t *partition = machine->partitions+partition_idx;

    int *shared_partitions = NULL;

    /* Build node list and find partition from node_names */
    netloc_node_t **node_list = NULL;
    if (num_nodes > 0) {
        node_list = (netloc_node_t **)malloc(sizeof(netloc_node_t *[num_nodes]));

        shared_partitions = (int *)calloc(machine->npartitions, sizeof(int));
        for (int p = 0; p < machine->npartitions; p++) {
            shared_partitions[p] = 1;
        }

        if (machine->explicit) {
            /* Look for nodes by name */
            for (int n = 0; n < num_nodes; n++) {
                netloc_node_t *node;
                HASH_FIND_STR(machine->explicit->nodes, node_names[n], node);
                assert(node);
                node_list[n] = node;

                for (int p = 0; p < node->nparts; p++) {
                    shared_partitions[node->newpartitions[p]]++;
                }
            }

        } else {
            assert(0); // TODO
        }

    }

    /* Check partitions shared by all nodes */
    if (shared_partitions) {
        int nfound = 0;
        int found_part = -1;
        int same = 0;
        for (int p = 0; p < machine->npartitions; ++p) {
            if (shared_partitions[p] == num_nodes) {
                nfound++;
                found_part = p;
                if (found_part == partition_idx) {
                    same = 1;
                }
            }
        }

        if (partition_idx != -1) {
            assert(same);

        } else {
            assert(nfound == 1);
            partition_idx = found_part;
        }
    }

    /* No recognized topology */
    if (!partition->topology) {
        explicit_to_deco(machine->explicit, &machine->partitions[partition_idx],
                num_nodes, node_list, arch, subarch);

    } else {
        netloc_topology_t *topology = partition->topology;
        if (topology->type == NETLOC_TOPOLOGY_TYPE_TREE) {
            if (!topology->subtopo) { /* Tree and nothing else */
                tree_to_tleaf(topology, arch);
                if (node_list) {
                    build_subarch(arch, partition_idx, num_nodes, node_list,
                            subarch);
                }

            } else { /* Hierachical topology */
                assert(0); // XXX TODO implement with deco
            }
        }
    }

    return 0;
}
