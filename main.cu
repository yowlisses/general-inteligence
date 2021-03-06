#include <cstdio>
#include <curand.h>
#include <curand_kernel.h>

#define SIZE 100

#define TYPE_AND 0
#define TYPE_AVA 1

#define cudaCheckError()                                                                       \
    {                                                                                          \
        cudaError_t e = cudaGetLastError();                                                    \
        if (e != cudaSuccess)                                                                  \
        {                                                                                      \
            printf("\nCuda failure %s:%d: '%s'\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
        }                                                                                      \
    }

struct Node;
__device__ Node *nodes;

__device__ Node *firstAva;
__device__ Node *actualAva;

struct Node
{
    char actualIndex;
    char type;
    bool alreadyUsed = false;
    float lastValue;

    //Posso substituir por ints ou shorts, já que nodes é uma memória contígua
    Node *childs[4];
    Node *calledBy;
    Node *parent;

    float weights[4];

    __device__ int id()
    {
        return (int)(this - nodes);
    }
};

__global__ void allocNodes()
{
    cudaMalloc(&nodes, sizeof(Node) * SIZE);
}

__global__ void initializeRandom()
{
    int i = blockIdx.x;
    int j = threadIdx.x;

    curandState_t state;
    curand_init(clock64(), i * blockDim.x + j, 0, &state);

    nodes[i].childs[j] = &nodes[curand(&state) % SIZE];
    // printf("nodes[%d].child[%d] = %d\n", i, j, nodes[i].childs[j]->id());

    if (j == 0)
    {
        nodes[i].calledBy = &nodes[curand(&state) % SIZE]; //impede receive para algo fora da memoria
        nodes[i].parent = &nodes[curand(&state) % SIZE];   //TESTING
        // printf("%d->Node[%d]\n", nodes[i].parent->id(), nodes[i].id());
    }

    nodes[i].lastValue = i;  //marcador, exemplo: Node[3].lastvalue = 3
    nodes[i].weights[j] = i; //marcador, exemplo: Node[3].weight[i] = 3

    nodes[i].alreadyUsed = false; //por segurança
    nodes[i].actualIndex = 0;

    nodes[i].type = (i + 1) % 5 == 0 ? TYPE_AVA : TYPE_AND; //para testes iniciais

    firstAva = &nodes[4];
    actualAva = &nodes[4];
}

__global__ void descendent(Node *parent, Node *parallelParent, int limit = 0)
{
    if (parent->alreadyUsed == true || limit >= 1)
        return;

    printf("Parent Node[%d] (%d, %d, %d, %d)\n",
           parent->id(),
           parent->childs[0]->id(),
           parent->childs[1]->id(),
           parent->childs[2]->id(),
           parent->childs[3]->id());

    parent->alreadyUsed = true;

    curandState_t state;
    curand_init(clock64(), 0, 0, &state);
    // Copy in parallel parent
    for (int i = 0; i < 4; i++)
    {
        parallelParent->childs[i] = &nodes[curand(&state) % SIZE];

        // And copy parent->childs[i] status ..
        for (int j = 0; j < 4; j++)
        {
            parallelParent->childs[i]->weights[j] = parent->childs[i]->weights[j];
        }
    }
    printf("Parallel parent Node[%d] (%d, %d, %d, %d)\n",
           parallelParent->id(),
           parallelParent->childs[0]->id(),
           parallelParent->childs[1]->id(),
           parallelParent->childs[2]->id(),
           parallelParent->childs[3]->id());

    // Iterate next steps
    for (int i = 0; i < 4; i++)
    {
        parallelParent->childs[i] = &nodes[curand(&state) % SIZE];
        descendent<<<1, 1>>>(parent->childs[i], parallelParent->childs[i], limit + 1);
        __syncthreads();
    }
}

__global__ void reproduce()
{
    curandState_t state;
    curand_init(clock64(), 0, 0, &state);
    Node *parallelParent = &nodes[curand(&state) % SIZE];
    descendent<<<1, 1>>>(nodes, parallelParent);
}

__device__ void addInAvaList(Node *newAva)
{
    actualAva->childs[1] = newAva;
    actualAva = newAva;
}

// setter set node
__device__ bool canSet(Node *setter, Node *node)
{
    // Posso adicionar mais e mais coisa como node->parent->parent == setter->parent
    // a depender de ajuste fino para manter a cadeia
    return (
        node->parent == setter ||
        node->parent == setter->parent ||
        node->parent->parent == setter ||
        node->parent->parent == setter->parent);
}

__global__ void call(Node *caller);

__global__ void receive(Node *receiver, float value, Node *from)
{
    receiver->actualIndex++;

    // printf("Node[%d] recebeu valor %.0f\n", receiver->id(), value);

    switch (receiver->type)
    {
    //Aqui tem maior ou igual porquw actualIndex varia bastante
    case TYPE_AND:
        if (receiver->actualIndex >= 4)
        {
            receiver->actualIndex = 0;
            receive<<<1, 1>>>(receiver->calledBy, value, receiver);
            // printf("Node[%d] (and) recebeu quatro vezes\n", receiver->id());
        }
        receiver->lastValue = value;
        break;
    case TYPE_AVA:
        // printf("Node[%d] eh do tipo AVA, actualIndex: %d\n", receiver->id(), receiver->actualIndex);
        if (receiver->actualIndex == 1) // Primeira vez nessa rodada
        {
            receiver->actualIndex = 2;
            receiver->childs[0] = from;
            addInAvaList(receiver);
            receiver->lastValue = value;
            printf("Node[%d] (ava) de Node[%d] pela primeira vez na rodada, lastvalue %d\n",
                   receiver->id(), from->id(), receiver->childs[0]->id(), (int)receiver->lastValue);
        }
        else
        {
            receiver->actualIndex = 1;
        }
        receive<<<1, 1>>>(receiver->calledBy, value, receiver);
        // printf("Node[%d] (ava) recebeu uma vezes\n", receiver->id());
        break;
    }

    receiver->alreadyUsed = false; //allow node to be called several times
    // printf("Node[%d] recebe de Node[%d], lastValue: %d\n", receiver->id(), from->id(), (int)receiver->lastValue);
}

__global__ void call(Node *caller)
{
    caller->alreadyUsed = true;

    int numberOfCallChildren = caller->type == TYPE_AVA ? 1 : 4;

    for (int i = 0; i < numberOfCallChildren; i++)
    {
        if (!caller->childs[i]->alreadyUsed)
        {
            caller->childs[i]->alreadyUsed = true;
            caller->childs[i]->calledBy = caller;
            call<<<1, 1>>>(caller->childs[i]);
            // printf("Node[%d], type %d, call Node[%d]\n", caller->id(), caller->type, caller->childs[i]->id());
        }
        else
        {
            receive<<<1, 1>>>(caller, caller->childs[i]->lastValue, caller->childs[i]);
            // printf("Node[%d] tentou chamar Node[%d] usado, recebe %.0f\n", caller->id(), caller->childs[i]->id(), caller->childs[i]->lastValue);
        }
    }

    // cudaCheckError();
}

__global__ void callFirst()
{
    call<<<1, 1>>>(nodes);
}

//NESCESSARY!
__global__ void resetAlreadyUseds()
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    nodes[i].alreadyUsed = false;
}

__global__ void logNodesLastValues()
{
    for (int i = 0; i < SIZE; i++)
    {
        printf("%d ", (int)nodes[i].weights[0]);
    }
}

__global__ void logAvaList()
{
    Node *trackNode = firstAva;
    printf("type firstAva: %d\n", firstAva->type);
    for (int i = 0; i < 20; i++)
    {
        if (trackNode->type != TYPE_AVA || trackNode->alreadyUsed)
            break;
        printf("->Node[%d] lastValue: %d\n", trackNode->id(), (int)trackNode->lastValue);
        trackNode->alreadyUsed = true;
        trackNode = trackNode->childs[1];
    }

    trackNode = firstAva;
    for (int i = 0; i < 20; i++)
    {
        if (trackNode->type != TYPE_AVA || !trackNode->alreadyUsed)
            break;
        trackNode->alreadyUsed = false;
        trackNode = trackNode->childs[1];
    }
}

int main()
{
    allocNodes<<<1, 1>>>();
    cudaDeviceSynchronize();
    initializeRandom<<<SIZE, 4>>>();
    cudaDeviceSynchronize();
    for (int i = 0; i < 1; i++)
    {
        callFirst<<<1, 1>>>();
        cudaDeviceSynchronize();
        resetAlreadyUseds<<<SIZE, 1>>>();
        cudaDeviceSynchronize();
        logAvaList<<<1, 1>>>();
        cudaDeviceSynchronize();
        // reproduce<<<1, 1>>>();
        // cudaDeviceSynchronize();
        // logNodesLastValues<<<1, 1>>>();
        // cudaDeviceSynchronize();
    }

    cudaCheckError();
}

//UriSE tenha DETERMINAÇÃO