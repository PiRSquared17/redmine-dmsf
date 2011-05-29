# Redmine plugin for Document Management System "Features"
#
# Copyright (C) 2011   Vít Jonáš <vit.jonas@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class DmsfFilesController < ApplicationController
  unloadable
  
  menu_item :dmsf
  
  before_filter :find_file
  before_filter :authorize

  def show
    # download is put here to provide more clear and usable links
    if params.has_key?(:download)
      if @file.deleted
        render_404
        return
      end
      if params[:download].blank?
        @revision = @file.last_revision
      else
        @revision = DmsfFileRevision.find(params[:download].to_i)
        if @revision.file != @file
          render_403
          return
        end
        if @revision.deleted
          render_404
          return
        end
      end
      Rails.logger.info "#{Time.now} from #{request.remote_ip}/#{request.env["HTTP_X_FORWARDED_FOR"]}: #{User.current.login} downloaded #{@project.identifier}://#{@file.dmsf_path_str} revision #{@revision.id}"
      check_project(@revision.file)
      send_revision
      return
    end
    
    @revision = @file.last_revision
    # TODO: line bellow is to handle old instalations with errors in data handling
    @revision.name = @file.name
  end

  #TODO: don't create revision if nothing change
  def update
    unless params[:dmsf_file_revision]
      redirect_to :action => "file_detail", :id => @project, :file_id => @file
      return
    end
    if @file.locked_for_user?
      flash[:error] = l(:error_file_is_locked)
      redirect_to :action => "file_detail", :id => @project, :file_id => @file
    else
      #TODO: validate folder_id
      @revision = DmsfFileRevision.new(params[:dmsf_file_revision])
      
      @revision.file = @file
      last_revision = @file.last_revision
      @revision.source_revision = last_revision
      @revision.user = User.current
      
      @revision.major_version = last_revision.major_version
      @revision.minor_version = last_revision.minor_version
      @revision.workflow = last_revision.workflow
      version = params[:version].to_i
      file_upload = params[:file_upload]
      if file_upload.nil?
        @revision.disk_filename = last_revision.disk_filename
        @revision.increase_version(version, false)
        @revision.mime_type = last_revision.mime_type
        @revision.size = last_revision.size
      else
        @revision.increase_version(version, true)
        @revision.size = file_upload.size
        @revision.disk_filename = @revision.new_storage_filename
        @revision.mime_type = Redmine::MimeType.of(file_upload.original_filename)
      end
      @revision.set_workflow(params[:workflow])
      
      @file.name = @revision.name
      @file.folder = @revision.folder
      
      if @revision.valid? && @file.valid?
        @revision.save!
        unless file_upload.nil?
          @revision.copy_file_content(file_upload)
        end
        
        if @file.locked?
          DmsfFileLock.file_lock_state(@file, false)
          flash[:notice] = l(:notice_file_unlocked) + ", "
        end
        @file.save!
        @file.reload
        
        flash[:notice] = (flash[:notice].nil? ? "" : flash[:notice]) + l(:notice_file_revision_created)
        Rails.logger.info "#{Time.now} from #{request.remote_ip}/#{request.env["HTTP_X_FORWARDED_FOR"]}: #{User.current.login} created new revision of file #{@project.identifier}://#{@file.dmsf_path_str}"
        begin
          DmsfMailer.deliver_files_updated(User.current, [@file])
        rescue ActionView::MissingTemplate => e
          Rails.logger.error "Could not send email notifications: " + e
        end
        redirect_to :action => "file_detail", :id => @project, :file_id => @file
      else
        render :action => "file_detail"
      end
    end
  end

  def destroy
    if !@file.nil?
      if @file.delete
        flash[:notice] = l(:notice_file_deleted)
        Rails.logger.info "#{Time.now} from #{request.remote_ip}/#{request.env["HTTP_X_FORWARDED_FOR"]}: #{User.current.login} deleted file #{@project.identifier}://#{@file.dmsf_path_str}"
        DmsfMailer.deliver_files_deleted(User.current, [@file])
      else
        flash[:error] = l(:error_file_is_locked)
      end
    end
    redirect_to :controller => "dmsf", :action => "index", :id => @project, :folder_id => @file.folder
  end

  def destroy_revision
    @revision = DmsfFileRevision.find(params[:revision_id])
    check_project(@revision.file)
    if @revision.file.locked_for_user?
      flash[:error] = l(:error_file_is_locked)
    else
      if !@revision.nil? && !@revision.deleted
        if @revision.file.revisions.size <= 1
          flash[:error] = l(:error_at_least_one_revision_must_be_present)
        else
          @revision.deleted = true
          @revision.deleted_by_user = User.current
          @revision.save
          flash[:notice] = l(:notice_revision_deleted)
          Rails.logger.info "#{Time.now} from #{request.remote_ip}/#{request.env["HTTP_X_FORWARDED_FOR"]}: #{User.current.login} deleted revision #{@project.identifier}://#{@revision.file.dmsf_path_str}/#{@revision.id}"
        end
      end
    end
    redirect_to :action => "file_detail", :id => @project, :file_id => @revision.file
  end

  private

  def send_revision
    send_file(@revision.disk_file, 
      :filename => filename_for_content_disposition(@revision.name),
      :type => @revision.detect_content_type, 
      :disposition => "attachment")
  end
  
  def find_file
    @file = DmsfFile.find(params[:id])
    @project = @file.project
  end

  def check_project(entry)
    if !entry.nil? && entry.project != @project
      raise DmsfAccessError, l(:error_entry_project_does_not_match_current_project) 
    end
  end
  
end