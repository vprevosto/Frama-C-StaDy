
FRAMAC_SHARE	:=$(shell frama-c.byte -print-path)
FRAMAC_LIBDIR	:=$(shell frama-c.byte -print-libpath)
PLUGIN_NAME	:= PCVA

PLUGIN_TESTS_DIRS := \
	behaviors \
	quantified \
	binary_search \
	bubble_sort \
	insertion_sort \
	merge_arrays \
	merge_sort \
	quick_sort \
	tcas \
	first_subset \
	next_subset \
	deleteSubstr0 \
	deleteSubstr1a \
	deleteSubstr1b \
	deleteSubstr1c \
	deleteSubstr1d \
	deleteSubstr2a \
	deleteSubstr2b \
	deleteSubstr2c \
	deleteSubstr3 \
	deleteSubstr4 \
	sum_array \
	num_of \
	struct
PLUGIN_PTESTS_OPTS := -j 1

PLUGIN_CMO	:= \
	options \
	utils \
	prop_id \
	states \
	sd_subst \
	pcva_socket \
	native_precond \
	sd_printer \
	register
PLUGIN_GUI_CMO 	:= register_gui 
include $(FRAMAC_SHARE)/Makefile.dynamic

