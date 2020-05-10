import ConfigParser
import collections
import os
import socket
import collections
from collections import OrderedDict

# import srvlookup
# import dnslib
# import dns.resolver
# from dnslib import DNSRecord, DNSQuestion, QTYPE


def incrementFailures():
    global failures
    failures = failures + 1


def build_dictionary(config, section):
    values = {k: v for k, v in config.items(section)}
    # values = {k: v for k, v in t}
    # for x in values.items():
    #     print x[0] + '=' + x[1]
    return values


def build_ordered_dictionary(config, section):
    values = list(config.items(section))
    dictionary = OrderedDict()
    for item in values:
        host = item[0]
        ip = item[1]
        dictionary[host] = ip
    return dictionary


def validate_forward_reverse (hostname_ip_address_dictionary):
    for host in hostname_ip_address_dictionary:

        expected_ip = hostname_ip_address_dictionary[host]
        fqdn = host + "." + cluster + "." + domain

        forward_description = expected_ip + "=" + fqdn
        reverse_description = fqdn + "=" + expected_ip
        # Forward lookup
        found = True
        try:
            nslookup = socket.gethostbyaddr(fqdn)
        except socket.gaierror:
            found = False
            print(forward_description + ": Failed");
            incrementFailures()

        if found:
            if nslookup[2].pop() == expected_ip:
                print(forward_description + ": Passed")
            else:
                print(forward_description + ": Failed");
                incrementFailures()
        else:
            print(forward_description + ": Failed")
            incrementFailures()

        # Reverse lookup
        found = True
        try:
            nslookup = socket.gethostbyaddr(expected_ip)
        except socket.gaierror:
            found = False
            print(reverse_description + ": Failed");

        except socket.herror:
            found = False

        if found:
            if nslookup[0] == fqdn:
                print(reverse_description + ": Passed")
            else:
                print(reverse_description + ": Failed")
                incrementFailures()
        else:
            print(reverse_description + ": Failed")
            incrementFailures()


# def lookup_service_record(cluster, domain):
#     global failures
#     found = True
#     service_name = "etcd-server-ssl"
#     print("\nValidating service record " + service_name)
#
#     try:
#         service = srvlookup.lookup(service_name, "tcp", cluster + "." + domain)
#         print("Hello")
#     except srvlookup.SRVQueryFailure:
#         found = False
#
#     if found:
#         print("Service found")
#     else:
#         print("Service Not found")


def validate_etcd_names(control_plane):

    i = 0
    for host in control_plane:

        found = True
        etcd = "etcd-" + str(i) + "." + cluster + "." + domain
        expected_ip = control_plane[host]
        forward_description = "etcd-" + str(i) + "." + cluster + "." + domain + "=" + expected_ip

        try:
            nslookup = socket.gethostbyaddr(etcd)

        except socket.gaierror:
            found = False

        # when multiple masters, this is what is returned
        # ('avsddslapic1.stageapi.mskcc.org', [], ['172.22.86.211'])
        # ('avsddslapic2.stageapi.mskcc.org', [], ['172.22.86.212'])
        # ('avsddslapic3.stageapi.mskcc.org', [], ['172.22.86.213'])
        if found:
            # if len(nslookup[2]) == len(control_plane):
            if nslookup[2].pop() == expected_ip:
                print(forward_description + ": Passed")
            else:
                print(forward_description + ": Failed")
                incrementFailures()
        else:
            print(forward_description + ": Failed")
            incrementFailures()
        i = i + 1


def validate_api_server():
    found = True

    api = "api" + "." + cluster + "." + domain
    expected_ip = api_load_balancer_ip
    message = api + "=" + api_load_balancer_ip

    try:
        nslookup = socket.gethostbyaddr(api)
    except socket.gaierror:
        found = False

    if found:
        if nslookup[2].pop() == expected_ip:
            print(message + ": Passed")
        else:
            print(message + ": Failed")
            incrementFailures()
    else:
        print(message + ": Failed")
        incrementFailures()

    api_int = "api-int" + "." + cluster + "." + domain
    message = api_int + "=" + api_load_balancer_ip
    try:
        nslookup = socket.gethostbyaddr(api)
    except socket.gaierror:
        found = False

    if found:
        if nslookup[2].pop() == expected_ip:
            print(message + ": Passed")
        else:
            print(message + ": Failed")
            incrementFailures()
    else:
        print(message + ": Failed")
        incrementFailures()


def validate_apps():
    found = True

    apps = "*" + "." + "apps" + "." + cluster + "." + domain
    expected_ip = default_ingress_load_balancer_ip
    message = apps + ": " + default_ingress_load_balancer_ip
    endpoint = "portal" + "." + "apps" + "." + cluster + "." + domain
    try:
        nslookup = socket.gethostbyaddr(endpoint)
    except socket.gaierror:
        found = False

    if found:
        if nslookup[2].pop() == expected_ip:
            print(message + ": Passed")
        else:
            print(message + ": Failed")
            incrementFailures()
    else:
        print(message + ": Failed")
        incrementFailures()


config = ConfigParser.ConfigParser()
raw_config = ConfigParser.RawConfigParser()

global failures
failures = 0

config.read('cluster.cfg')
cluster = config.get('network', 'cluster')
domain = config.get('network', 'domain')

control_plane = build_ordered_dictionary(config, 'control_plane')
workers = build_ordered_dictionary(config, 'workers')
api_load_balancer_ip = config.get('load_balancers', 'api')
default_ingress_load_balancer_ip = config.get('load_balancers', 'ingress')

print("Validating forward and reverse nslookups for control plane")
validate_forward_reverse(control_plane);

print("\n\nValidating forward and reverse nslookups for worker nodes")
validate_forward_reverse( workers );
# print("\nValidating service record")
# lookup_service_record(cluster, domain)

print("\nValidating etcd member DNS updates")
validate_etcd_names(control_plane)

print("\nValidating API Server DNS updates")
validate_api_server()

print("\nValidating Routes DNS updates")
validate_apps()

print("\n**********************")
print("Total validation failures: " + str(failures))