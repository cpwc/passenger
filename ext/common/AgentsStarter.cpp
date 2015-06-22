/*
 *  Phusion Passenger - https://www.phusionpassenger.com/
 *  Copyright (c) 2010-2015 Phusion
 *
 *  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
 *
 *  See LICENSE file for license information.
 */
#include <oxt/thread.hpp>
#include <set>
#include <cerrno>
#include <cstring>
#include <string.h>
#include <AgentsStarter.h>
#include <Exceptions.h>

using namespace std;
using namespace boost;
using namespace oxt;


PP_VariantMap *
pp_variant_map_new() {
	return (PP_VariantMap *) new Passenger::VariantMap();
}

void
pp_variant_map_set(PP_VariantMap *m,
	const char *name,
	const char *value,
	unsigned int value_len)
{
	Passenger::VariantMap *vm = (Passenger::VariantMap *) m;
	vm->set(name, string(value, value_len));
}

void
pp_variant_map_set2(PP_VariantMap *m,
	const char *name,
	unsigned int name_len,
	const char *value,
	unsigned int value_len)
{
	Passenger::VariantMap *vm = (Passenger::VariantMap *) m;
	vm->set(string(name, name_len), string(value, value_len));
}

void
pp_variant_map_set_int(PP_VariantMap *m,
	const char *name,
	int value)
{
	Passenger::VariantMap *vm = (Passenger::VariantMap *) m;
	vm->setInt(name, value);
}

void
pp_variant_map_set_bool(PP_VariantMap *m,
	const char *name,
	int value)
{
	Passenger::VariantMap *vm = (Passenger::VariantMap *) m;
	vm->setBool(name, value);
}

void
pp_variant_map_set_strset(PP_VariantMap *m,
	const char *name,
	const char **strs,
	unsigned int count)
{
	Passenger::VariantMap *vm = (Passenger::VariantMap *) m;
	std::set<string> the_set;

	for (unsigned int i = 0; i < count; i++) {
		the_set.insert(strs[i]);
	}
	vm->setStrSet(name, the_set);
}

void
pp_variant_map_free(PP_VariantMap *m) {
	delete (Passenger::VariantMap *) m;
}


PP_AgentsStarter *
pp_agents_starter_new(PP_AgentsStarterType type, char **error_message) {
	return (PP_AgentsStarter *) new Passenger::AgentsStarter(type);
}

int
pp_agents_starter_start(PP_AgentsStarter *as,
	const char *passengerRoot,
	PP_VariantMap *extraParams,
	const PP_AfterForkCallback afterFork,
	void *callbackArgument,
	char **errorMessage)
{
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	this_thread::disable_syscall_interruption dsi;
	try {
		boost::function<void ()> afterForkFunctionObject;

		if (afterFork != NULL) {
			afterForkFunctionObject = boost::bind(afterFork, callbackArgument);
		}
		agentsStarter->start(passengerRoot,
			*((Passenger::VariantMap *) extraParams),
			afterForkFunctionObject);
		return 1;
	} catch (const Passenger::SystemException &e) {
		errno = e.code();
		*errorMessage = strdup(e.what());
		return 0;
	} catch (const std::exception &e) {
		errno = -1;
		*errorMessage = strdup(e.what());
		return 0;
	}
}

const char *
pp_agents_starter_get_core_address(PP_AgentsStarter *as, unsigned int *size) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	if (size != NULL) {
		*size = agentsStarter->getCoreAddress().size();
	}
	return agentsStarter->getCoreAddress().c_str();
}

const char *
pp_agents_starter_get_core_password(PP_AgentsStarter *as, unsigned int *size) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	if (size != NULL) {
		*size = agentsStarter->getCorePassword().size();
	}
	return agentsStarter->getCorePassword().c_str();
}

const char *
pp_agents_starter_get_instance_dir(PP_AgentsStarter *as, unsigned int *size) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	if (size != NULL) {
		*size = agentsStarter->getInstanceDir().size();
	}
	return agentsStarter->getInstanceDir().c_str();
}

pid_t
pp_agents_starter_get_pid(PP_AgentsStarter *as) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	return agentsStarter->getPid();
}

void
pp_agents_starter_detach(PP_AgentsStarter *as) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	agentsStarter->detach();
}

void
pp_agents_starter_free(PP_AgentsStarter *as) {
	Passenger::AgentsStarter *agentsStarter = (Passenger::AgentsStarter *) as;
	delete agentsStarter;
}
