#ifndef STADY_EXTERNAL_H
#define STADY_EXTERNAL_H
#include <stdlib.h>
#include <stdio.h>

struct __anonstruct___mpz_struct_1 {
  int _mp_alloc ;
  int _mp_size ;
  unsigned long *_mp_d ;
};
typedef struct __anonstruct___mpz_struct_1 __mpz_struct;
typedef __mpz_struct mpz_t[1];
extern unsigned long int __gmpz_get_ui(mpz_t);
extern signed long int __gmpz_get_si(mpz_t);
extern int __gmpz_cmp_ui(mpz_t, unsigned long int);
extern int __gmpz_cmp_si(mpz_t, signed long int);
extern int __gmpz_cmp(mpz_t, mpz_t);
extern void __gmpz_clear(mpz_t);
extern void __gmpz_init(mpz_t);
extern void __gmpz_init_set(mpz_t, mpz_t);
extern void __gmpz_init_set_ui(mpz_t, unsigned long int);
extern void __gmpz_init_set_si(mpz_t, signed long int);
extern void __gmpz_init_set_str(mpz_t, const char*, int);
extern void __gmpz_set(mpz_t, mpz_t);
extern void __gmpz_abs(mpz_t, mpz_t);
extern void __gmpz_add(mpz_t, const mpz_t, const mpz_t);
extern void __gmpz_add_ui(mpz_t, const mpz_t, unsigned long int);
extern void __gmpz_sub(mpz_t, const mpz_t, const mpz_t);
extern void __gmpz_sub_ui(mpz_t, const mpz_t, unsigned long int);
extern void __gmpz_ui_sub(mpz_t, unsigned long int, const mpz_t);
extern void __gmpz_mul(mpz_t, const mpz_t, const mpz_t);
extern void __gmpz_mul_si(mpz_t, const mpz_t, long int);
extern void __gmpz_mul_ui(mpz_t, const mpz_t, unsigned long int);
extern void __gmpz_tdiv_q(mpz_t, const mpz_t, const mpz_t);
extern void __gmpz_tdiv_q_ui(mpz_t, const mpz_t, unsigned long int);
extern void __gmpz_tdiv_r(mpz_t, const mpz_t, const mpz_t);
extern void __gmpz_tdiv_r_ui(mpz_t, const mpz_t, unsigned long int);
#define mp_bitcnt_t unsigned long long
extern void __gmpz_mul_2exp(mpz_t rop, const mpz_t op1, mp_bitcnt_t op2);
extern void __gmpz_fdiv_q_2exp(mpz_t q, const mpz_t n, mp_bitcnt_t b);
extern void __gmpz_and(mpz_t x, const mpz_t y, const mpz_t z);
extern void __gmpz_ior(mpz_t x, const mpz_t y, const mpz_t z);
extern void __gmpz_xor(mpz_t x, const mpz_t y, const mpz_t z);
extern int pathcrawler_assert_exception(char*,int);
extern int pathcrawler_dimension(void*);
extern void pathcrawler_to_framac(char*);
extern int pathcrawler_assume_exception(char*,int);
#endif
