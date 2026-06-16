#include <stdint.h>
extern uint32_t kvstore_run(void);
int main(void){return kvstore_run()==1?0:1;}
