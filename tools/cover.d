/*
 *  The MIT License (MIT)
 *  =====================
 *
 *  Copyright (c) 2015 Dmitri Makarov <dmakarov@alumni.stanford.edu>
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 */

import std.stdio;
import etc.c.curl;
import core.sys.posix.sys.time;

void post()
{
  CURL *curl;
  CURLM *multi_handle;
  int still_running;

  curl_httppost *formpost;
  curl_httppost *lastptr;
  curl_slist *headerlist;

  /* Fill in the file upload field. This makes libcurl load data from
     the given file name when curl_easy_perform() is called. */
  const char[] copyname1 = "sendfile";
  const char[] file = "json_file";
  curl_formadd(&formpost,
               &lastptr,
               CurlForm.copyname, copyname1.ptr,
               CurlForm.file, file.ptr,
               CurlForm.end);

  // Fill in the filename field
  const char[] copyname2 = "filename";
  curl_formadd(&formpost,
               &lastptr,
               CurlForm.copyname, copyname2.ptr,
               CurlForm.copycontents, file.ptr,
               CurlForm.end);

  // Fill in the submit field too, even if this is rarely needed
  const char[] copyname3 = "submit";
  const char[] copycontents = "send";
  curl_formadd(&formpost,
               &lastptr,
               CurlForm.copyname, copyname3.ptr,
               CurlForm.copycontents, copycontents.ptr,
               CurlForm.end);

  curl = curl_easy_init();
  multi_handle = curl_multi_init();

  // initalize custom header list (stating that Expect: 100-continue is not wanted
  const char[] buf = "Expect:";
  headerlist = curl_slist_append(headerlist, buf.ptr);
  if (curl && multi_handle)
  {
    // what URL that receives this POST "http://httpbin.org/post";
    const char[] url = "https://coveralls.io/api/v1/jobs";
    curl_easy_setopt(curl, CurlOption.url, url.ptr);
    curl_easy_setopt(curl, CurlOption.verbose, 1L);

    curl_easy_setopt(curl, CurlOption.httpheader, headerlist);
    curl_easy_setopt(curl, CurlOption.httppost, formpost);

    curl_multi_add_handle(multi_handle, curl);

    curl_multi_perform(multi_handle, &still_running);

    do
    {
      timeval timeout;
      int rc; /* select() return code */
      CURLMcode mc; /* curl_multi_fdset() return code */

      core.sys.posix.sys.select.fd_set fdread;
      core.sys.posix.sys.select.fd_set fdwrite;
      core.sys.posix.sys.select.fd_set fdexcep;
      int maxfd = -1;

      long curl_timeo = -1;

      /* set a suitable timeout to play around with */
      timeout.tv_sec = 1;
      timeout.tv_usec = 0;

      curl_multi_timeout(multi_handle, &curl_timeo);
      if (curl_timeo >= 0)
      {
        timeout.tv_sec = curl_timeo / 1000;
        if (timeout.tv_sec > 1)
        {
          timeout.tv_sec = 1;
        }
        else
        {
          timeout.tv_usec = (curl_timeo % 1000) * 1000;
        }
      }

      /* get file descriptors from the transfers */
      mc = curl_multi_fdset(multi_handle,
                            cast(int*) &fdread,
                            cast(int*) &fdwrite,
                            cast(int*) &fdexcep,
                            &maxfd);

      if (mc != CurlM.ok)
      {
        writefln("curl_multi_fdset() failed, code %d.\n", mc);
        break;
      }

      /* On success the value of maxfd is guaranteed to be >= -1. We call
         select(maxfd + 1, ...); specially in case of (maxfd == -1) there are
         no fds ready yet so we call select(0, ...) --or Sleep() on Windows--
         to sleep 100ms, which is the minimum suggested value in the
         curl_multi_fdset() doc. */

      if (maxfd == -1)
      {
        /* Portable sleep for platforms other than Windows. */
        timeval wait = { 0, 100 * 1000 }; /* 100ms */
        rc = select(0, null, null, null, &wait);
      }
      else
      {
        /* Note that on some platforms 'timeout' may be modified by select().
           If you need access to the original value save a copy beforehand. */
        rc = select(maxfd+1, &fdread, &fdwrite, &fdexcep, &timeout);
      }

      if (rc != -1)
      {
        /* timeout or readable/writable sockets */
        writeln("perform!");
        curl_multi_perform(multi_handle, &still_running);
        writefln("running: %d!", still_running);
      }
    } while(still_running);

    curl_multi_cleanup(multi_handle);

    // always cleanup
    curl_easy_cleanup(curl);

    // then cleanup the formpost chain
    curl_formfree(formpost);

    // free slist
    curl_slist_free_all (headerlist);
  }
}

void main(string[] args)
{
  import std.algorithm.iteration : filter;
  import std.algorithm.searching : endsWith, find;
  import std.array, std.conv, std.digest.md, std.file, std.format;
  import std.process, std.range, std.regex;

  immutable coverage_filename_predicate = `endsWith(a.name, ".lst") && find(a.name, ".dub-packages").empty`;
  auto coverage_files = dirEntries(".", SpanMode.depth).filter!coverage_filename_predicate;
  auto whole_line_regex = regex(`^( *)([0-9]*)\|.*$`, "g");
  auto output_file = File("json_file", "w");
  auto job_id = environment.get("TRAVIS_JOB_ID", "");
  output_file.writef(`{
  "service_job_id" : "%s",
  "service_name" : "travis-ci",
  "source_files" : [`, job_id);
  auto file_block_comma = "";
  foreach (filename; coverage_files)
  {
    auto input_file = File(filename, "r");
    auto source_filename = filename.replaceFirst("./", "").replace("-", "/").replaceLast(".lst", ".d");
    MD5 source_digest;
    source_digest.start();
    auto source_file = File(source_filename, "rb");
    put(source_digest, source_file.byChunk(1024));
    output_file.writef(`%s
    {
      "name" : "%s",
      "source_digest" : "%s",
      "coverage" : [`, file_block_comma, source_filename, toHexString(source_digest.finish()));
    auto coverage_item_comma = "";
    foreach (line; input_file.byLine())
    {
      auto captures = line.matchFirst(whole_line_regex);
      if (!captures.empty())
      {
        auto line_coverage = captures[2].empty ? "null" : captures[2];
        output_file.writef("%s%s", coverage_item_comma, line_coverage);
      }
      coverage_item_comma = ", ";
    }
    output_file.writef("]\n    }");
    file_block_comma = ",";
  }
  output_file.writef("\n  ]\n}\n");
  output_file.close();
  post();
}
