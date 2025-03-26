output "Network_Load_Balancer_Address" {
  value = yandex_lb_network_load_balancer.nlb.listener.*.external_address_spec[0].*.address
  description = "Адрес NLB"
} 


output "Application_Load_Balancer_Address" {
  value = yandex_alb_load_balancer.application-balancer.listener.*.endpoint[0].*.address[0].*.external_ipv4_address
  description = "Адрес APL"
}