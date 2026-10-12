// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
import * as model from '/usr/libexec/podkop-tools/model.uc';
let count=0;
function check(condition,label){if(!condition)die(label);count++;}
check(type(model.service_sample)=='function','service_sample_missing');
let service_sample=model.service_sample;
let body='<html><title>Telegram Web</title><meta content="https://web.telegram.org/k/"><script type="module"></script></html>';
let markers=['<title>Telegram Web</title>','content="https://web.telegram.org/k/"','<script type="module"'];
let m={http_code:200,content_type:'text/html; charset=utf-8',ssl_verify_result:0,num_redirects:0,size_download:length(body)};
check(service_sample(m,0,body,200,'text/html',markers).ok,'strict_service_success');
check(!service_sample(m,60,body,200,'text/html',markers).ok,'invalid_TLS_is_not_reachability');
m.http_code=403;check(!service_sample(m,0,body,200,'text/html',markers).ok,'403_is_not_success');
m.http_code=302;check(!service_sample(m,0,body,200,'text/html',markers).ok,'redirect_is_not_success');
m.http_code=200;check(!service_sample(m,0,'<html>Hello</html>',200,'text/html',markers).ok,'arbitrary_200_is_not_success');
check(!service_sample(m,0,body+'Access denied',200,'text/html',markers).ok,'blocking_page_with_positive_markers_rejected');
m.content_type='application/json';check(!service_sample(m,0,body,200,'text/html',markers).ok,'unexpected_content_type_rejected');
m.content_type='text/html';m.ssl_verify_result=1;check(!service_sample(m,0,body,200,'text/html',markers).ok,'verification_result_checked');
m.ssl_verify_result=0;m.num_redirects=1;check(!service_sample(m,0,body,200,'text/html',markers).ok,'followed_redirect_rejected');
m.num_redirects=0;check(!service_sample(m,28,body,200,'text/html',markers).ok,'partial_timeout_cannot_claim_service_success');
check(!service_sample(m,63,body,200,'text/html',markers).ok,'partial_over_cap_cannot_claim_service_success');
check(!service_sample(m,0,body,403,'text/html',markers).ok,'configuration_cannot_accept_403');
check(!service_sample(m,0,body,200,'text/html',[]).ok,'empty_content_contract_rejected');
check(service_sample({http_code:201,content_type:'application/json',ssl_verify_result:0,num_redirects:0},0,'{"service":"fixture-ready"}',201,'application/json',['"service":"fixture-ready"']).ok,'custom_endpoint_exact_contract');
printf('%J\n',{passed:count});
